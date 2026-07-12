// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "src/MockUSDC.sol";
import {BondedRegistry} from "src/BondedRegistry.sol";
import {PolicyManager} from "src/PolicyManager.sol";
import {SettlementRouter} from "src/SettlementRouter.sol";
import {ClaimManager} from "src/ClaimManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Chain-agnostic deployment. Same script targets Arbitrum Sepolia today and
/// Robinhood Chain via RPC config — deployment there is claimed only once executed.
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --broadcast --verify
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", deployer);

        uint256 receiptWindow = vm.envOr("RECEIPT_WINDOW", uint256(60));
        uint256 claimWindow = vm.envOr("CLAIM_WINDOW", uint256(1 days));
        uint256 defenseWindow = vm.envOr("DEFENSE_WINDOW", uint256(60));
        uint256 cooldown = vm.envOr("WITHDRAW_COOLDOWN", uint256(120));

        vm.startBroadcast(pk);

        MockUSDC usdc = new MockUSDC();
        BondedRegistry registry = new BondedRegistry(
            IERC20(address(usdc)),
            100e6, // minBond: 100 mUSDC
            cooldown,
            2_000 // delist above 20% failure ratio
        );

        // PolicyManager needs the router address (deployed next): predict it.
        address routerPredicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        PolicyManager policy = new PolicyManager(routerPredicted);
        SettlementRouter router = new SettlementRouter(
            IERC20(address(usdc)), registry, policy, receiptWindow, claimWindow
        );
        require(address(router) == routerPredicted, "router prediction failed");

        ClaimManager cm = new ClaimManager(
            IERC20(address(usdc)),
            registry,
            router,
            treasury,
            3, // minBatch
            50e6, // single-payment high-value floor
            defenseWindow,
            2_000, // penalty: 20% of refund total
            7_500, // watcher share: 75% of penalty
            1_000, // claim stake: 10% of refund total
            10e6 // stake floor: 10 mUSDC
        );

        registry.wire(address(router), address(cm));
        router.wire(address(cm));

        // Endpoint-ownership oracle (the watcher). Defaults to the deployer so
        // the demo can verify listings; set VERIFIER to the watcher key in prod.
        address verifier = vm.envOr("VERIFIER", deployer);
        registry.setVerifier(verifier);

        vm.stopBroadcast();

        console.log("MockUSDC        ", address(usdc));
        console.log("BondedRegistry  ", address(registry));
        console.log("PolicyManager   ", address(policy));
        console.log("SettlementRouter", address(router));
        console.log("ClaimManager    ", address(cm));
    }
}
