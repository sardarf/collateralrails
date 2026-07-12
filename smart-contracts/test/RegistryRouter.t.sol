// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {BondedRegistry} from "src/BondedRegistry.sol";
import {SettlementRouter} from "src/SettlementRouter.sol";
import {PolicyManager} from "src/PolicyManager.sol";

contract RegistryRouterTest is BaseTest {
    // ------------------------------------------------------------ registry

    function test_RegisterWithMinBond() public {
        _register(honest, MIN_BOND);
        (uint256 bond,,,,,, bool active,,) = registry.getSeller(honest);
        assertEq(bond, MIN_BOND);
        assertTrue(active);
        assertTrue(registry.isActive(honest));
        assertEq(registry.sellerCount(), 1);
    }

    function test_RevertRegisterBelowMinBond() public {
        vm.startPrank(honest);
        usdc.approve(address(registry), type(uint256).max);
        vm.expectRevert(BondedRegistry.BondTooLow.selector);
        registry.register(MIN_BOND - 1, "x", "https://x.example");
        vm.stopPrank();
    }

    function test_RevertDoubleRegister() public {
        _register(honest, MIN_BOND);
        vm.prank(honest);
        vm.expectRevert(BondedRegistry.AlreadyRegistered.selector);
        registry.register(MIN_BOND, "x", "https://x.example");
    }

    // ------------------------------------------------- handles (anti-impersonation)

    function test_HandleMustBeUnique() public {
        vm.startPrank(honest);
        usdc.approve(address(registry), type(uint256).max);
        registry.register(MIN_BOND, "acme", "https://acme.example");
        vm.stopPrank();

        // Case-insensitive collision: "ACME" normalises to "acme".
        vm.startPrank(deadbeat);
        usdc.approve(address(registry), type(uint256).max);
        vm.expectRevert(BondedRegistry.HandleTaken.selector);
        registry.register(MIN_BOND, "ACME", "https://evil.example");
        vm.stopPrank();

        assertEq(registry.handleOwner(keccak256("acme")), honest);
    }

    function test_RejectsEmptyHandle() public {
        vm.startPrank(honest);
        usdc.approve(address(registry), type(uint256).max);
        vm.expectRevert(BondedRegistry.InvalidHandle.selector);
        registry.register(MIN_BOND, "", "https://acme.example");
        vm.stopPrank();
    }

    // ------------------------------------------------- endpoint verification

    function test_OnlyVerifierCanVerify() public {
        _register(honest, MIN_BOND);
        (,, bool verifiedBefore) = registry.identity(honest);
        assertFalse(verifiedBefore);

        vm.prank(buyer); // not the verifier
        vm.expectRevert(BondedRegistry.NotAuthorized.selector);
        registry.verifyEndpoint(honest);

        vm.prank(watcher); // the wired verifier
        registry.verifyEndpoint(honest);
        (,, bool verifiedAfter) = registry.identity(honest);
        assertTrue(verifiedAfter);
    }

    // ------------------------------------------------- reputation view

    function test_ReputationNewSellerIsUnproven() public {
        _register(honest, MIN_BOND);
        (uint16 score, uint8 tier, bool flagged) = registry.reputation(honest);
        assertEq(score, 0);
        assertEq(tier, registry.TIER_NEW());
        assertFalse(flagged);
    }

    function test_ReputationRisesWithDeliveries() public {
        _register(honest, MIN_BOND);
        _payN(honest, 5); // 5 served, 0 failed
        (uint16 score, uint8 tier, bool flagged) = registry.reputation(honest);
        assertGt(score, 0);
        assertFalse(flagged);
        assertTrue(tier != registry.TIER_NEW() && tier != registry.TIER_FLAGGED());
    }

    function test_ReputationDepositCannotBuyRank() public {
        // A huge deposit but zero deliveries must still read as unproven.
        _register(honest, 1_000e6);
        (uint16 score, uint8 tier,) = registry.reputation(honest);
        assertEq(score, 0);
        assertEq(tier, registry.TIER_NEW());
    }

    function test_ReputationFlaggedAfterSlash() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 5);
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);
        _endDefense();
        cm.resolve(claimId);

        (, uint8 tier, bool flagged) = registry.reputation(deadbeat);
        assertTrue(flagged);
        assertEq(tier, registry.TIER_FLAGGED());
    }

    function test_TopUpIncreasesBond() public {
        _register(honest, MIN_BOND);
        vm.prank(honest);
        registry.topUp(50e6);
        (uint256 bond,,,,,,,,) = registry.getSeller(honest);
        assertEq(bond, MIN_BOND + 50e6);
    }

    function test_WithdrawalCooldownEnforced() public {
        _register(honest, MIN_BOND);
        vm.prank(honest);
        registry.requestWithdrawal();
        assertFalse(registry.isActive(honest)); // deactivated immediately

        vm.prank(honest);
        vm.expectRevert(BondedRegistry.CooldownActive.selector);
        registry.executeWithdrawal();

        vm.warp(block.timestamp + COOLDOWN + 1);
        uint256 balBefore = usdc.balanceOf(honest);
        vm.prank(honest);
        registry.executeWithdrawal();
        assertEq(usdc.balanceOf(honest), balBefore + MIN_BOND);
    }

    function test_WithdrawalBlockedWhileClaimOpen() public {
        _register(deadbeat, 500e6);
        uint256[] memory ids = _payN(deadbeat, 3);
        _expireReceipts();
        vm.prank(watcher);
        cm.fileClaim(deadbeat, ids);

        vm.prank(deadbeat);
        registry.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(deadbeat);
        vm.expectRevert(BondedRegistry.OpenClaimsExist.selector);
        registry.executeWithdrawal();
    }

    function test_WithdrawalBlockedWhileExposureOpen() public {
        _register(honest, 500e6);
        _pay(honest, CALL_PRICE, keccak256("r"));
        vm.prank(honest);
        registry.requestWithdrawal();
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(honest);
        vm.expectRevert(BondedRegistry.OpenExposureExists.selector);
        registry.executeWithdrawal();
    }

    function test_OnlyClaimManagerCanSlash() public {
        _register(honest, MIN_BOND);
        address[] memory b = new address[](0);
        uint256[] memory r = new uint256[](0);
        vm.expectRevert(BondedRegistry.NotAuthorized.selector);
        registry.slash(honest, b, r, 0, 0, address(0), 0, address(0));
    }

    // ------------------------------------------------------------ policy

    function test_PolicyPerPaymentCap() public {
        _register(honest, 500e6);
        vm.prank(buyer);
        vm.expectRevert(PolicyManager.ExceedsPerPaymentCap.selector);
        router.pay(honest, 200_001, keccak256("r")); // cap is $0.20
    }

    function test_PolicyBudgetDepletion() public {
        _register(honest, 500e6);
        vm.startPrank(buyer);
        policy.setPolicy(uint128(200_000), uint128(250_000), uint64(block.timestamp + 1 days), true, false);
        router.pay(honest, 150_000, keccak256("a"));
        vm.expectRevert(PolicyManager.ExceedsBudget.selector);
        router.pay(honest, 150_000, keccak256("b"));
        vm.stopPrank();
    }

    function test_PolicyExpiry() public {
        _register(honest, 500e6);
        vm.prank(buyer);
        policy.setPolicy(uint128(200_000), uint128(1e6), uint64(block.timestamp + 10), true, false);
        vm.warp(block.timestamp + 11);
        vm.prank(buyer);
        vm.expectRevert(PolicyManager.PolicyExpired.selector);
        router.pay(honest, CALL_PRICE, keccak256("r"));
    }

    function test_PolicyAllowlist() public {
        _register(honest, 500e6);
        _register(deadbeat, 500e6);
        vm.startPrank(buyer);
        policy.setPolicy(uint128(200_000), uint128(1e6), uint64(block.timestamp + 1 days), true, true);
        policy.setAllowed(honest, true);
        router.pay(honest, CALL_PRICE, keccak256("ok"));
        vm.expectRevert(PolicyManager.SellerNotAllowed.selector);
        router.pay(deadbeat, CALL_PRICE, keccak256("no"));
        vm.stopPrank();
    }

    function test_OnlyRouterConsumesPolicy() public {
        vm.expectRevert(PolicyManager.NotRouter.selector);
        policy.checkAndConsume(buyer, honest, 1);
    }

    // ------------------------------------------------------------ router

    function test_PayInstantSettlementNoEscrow() public {
        _register(honest, 500e6);
        uint256 sellerBefore = usdc.balanceOf(honest);
        uint256 routerBefore = usdc.balanceOf(address(router));

        uint256 id = _pay(honest, CALL_PRICE, keccak256("req"));

        // seller received funds immediately; router holds nothing extra
        assertEq(usdc.balanceOf(honest), sellerBefore + CALL_PRICE);
        assertEq(usdc.balanceOf(address(router)), routerBefore - CALL_PRICE);

        SettlementRouter.Payment memory p = router.getPayment(id);
        assertEq(uint8(p.status), uint8(SettlementRouter.Status.Settled));
        assertEq(p.amount, CALL_PRICE);
        assertEq(p.buyer, buyer);
    }

    function test_RevertPayUnbondedSeller() public {
        // never registered; default policy has requireBonded=true, so the
        // router's bonded-check fires before the registry's activity check
        vm.prank(buyer);
        vm.expectRevert(SettlementRouter.SellerNotBonded.selector);
        router.pay(makeAddr("ghost"), CALL_PRICE, keccak256("r"));
    }

    function test_RevertPayInactiveSellerWithoutBondedPolicy() public {
        // with requireBonded=false the registry's own check is the backstop:
        // inactive/unregistered sellers still cannot be paid
        vm.startPrank(buyer);
        policy.setPolicy(uint128(200_000), uint128(1e6), uint64(block.timestamp + 1 days), false, false);
        vm.expectRevert(BondedRegistry.SellerInactive.selector);
        router.pay(makeAddr("ghost"), CALL_PRICE, keccak256("r"));
        vm.stopPrank();
    }

    function test_RevertPayDelistedSeller() public {
        _register(deadbeat, 500e6);
        _slashDeadbeat(5);
        assertFalse(registry.isActive(deadbeat));
        vm.prank(buyer);
        vm.expectRevert(SettlementRouter.SellerNotBonded.selector);
        router.pay(deadbeat, CALL_PRICE, keccak256("r"));
    }

    function test_ExposureNeverExceedsBond() public {
        // bond exactly covers 3 calls; 4th must revert
        _register(honest, MIN_BOND);
        vm.startPrank(buyer);
        router.deposit(200e6); // ample balance: the bond cap must be the binding constraint
        policy.setPolicy(uint128(50e6), uint128(500e6), uint64(block.timestamp + 1 days), true, false);
        router.pay(honest, 40e6, keccak256("1"));
        router.pay(honest, 40e6, keccak256("2"));
        vm.expectRevert(BondedRegistry.ExposureExceedsBond.selector);
        router.pay(honest, 40e6, keccak256("3")); // 120 > 100 bond
        vm.stopPrank();
    }

    function test_ReleaseExpiredFreesExposureAfterClaimWindow() public {
        _register(honest, MIN_BOND);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("r"));
        vm.warp(block.timestamp + RECEIPT_WINDOW + CLAIM_WINDOW + 2);
        router.releaseExpired(id);
        (, uint256 exposure,,,,,,,) = registry.getSeller(honest);
        assertEq(exposure, 0);
    }

    function test_RevertReleaseExpiredDuringClaimWindow() public {
        _register(honest, MIN_BOND);
        uint256 id = _pay(honest, CALL_PRICE, keccak256("r"));
        _expireReceipts();
        vm.expectRevert(SettlementRouter.ClaimWindowStillOpen.selector);
        router.releaseExpired(id);
    }

    // ------------------------------------------------------------ util

    function _slashDeadbeat(uint256 n) internal {
        uint256[] memory ids = _payN(deadbeat, n);
        _expireReceipts();
        vm.prank(watcher);
        uint256 claimId = cm.fileClaim(deadbeat, ids);
        _endDefense();
        cm.resolve(claimId);
    }
}
