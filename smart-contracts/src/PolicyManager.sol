// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PolicyManager
/// @notice Thin buyer-side spending policy: per-payment cap, total budget,
///         expiry, optional seller allowlist, bonded-only flag (enforced by
///         the ROUTER via the registry). Bounded-agency pattern: the agent
///         proposes payments, this contract enforces the human's rules.
contract PolicyManager {
    using SafeCast for uint256;
    struct Policy {
        uint128 maxPerPayment;
        uint128 budget;
        uint128 spent;
        uint64 expiry;
        bool requireBonded;
        bool useAllowlist;
        bool exists;
    }

    address public immutable ROUTER;

    mapping(address => Policy) public policies;
    mapping(address => mapping(address => bool)) public allowedSeller;

    event PolicySet(
        address indexed buyer,
        uint256 maxPerPayment,
        uint256 budget,
        uint64 expiry,
        bool requireBonded,
        bool useAllowlist
    );
    event AllowlistUpdated(address indexed buyer, address indexed seller, bool allowed);
    event BudgetConsumed(address indexed buyer, address indexed seller, uint256 amount, uint256 spent);

    error NotRouter();
    error NoPolicy();
    error PolicyExpired();
    error ExceedsPerPaymentCap();
    error ExceedsBudget();
    error SellerNotAllowed();

    constructor(address _router) {
        ROUTER = _router;
    }

    function setPolicy(
        uint128 maxPerPayment,
        uint128 budget,
        uint64 expiry,
        bool requireBonded,
        bool useAllowlist
    ) external {
        policies[msg.sender] = Policy({
            maxPerPayment: maxPerPayment,
            budget: budget,
            spent: 0,
            expiry: expiry,
            requireBonded: requireBonded,
            useAllowlist: useAllowlist,
            exists: true
        });
        emit PolicySet(msg.sender, maxPerPayment, budget, expiry, requireBonded, useAllowlist);
    }

    function setAllowed(address seller, bool allowed) external {
        allowedSeller[msg.sender][seller] = allowed;
        emit AllowlistUpdated(msg.sender, seller, allowed);
    }

    /// @notice Router-only: validates and consumes budget atomically before transfer.
    function checkAndConsume(address buyer, address seller, uint256 amount)
        external
        returns (bool requireBonded)
    {
        if (msg.sender != ROUTER) revert NotRouter();
        Policy storage p = policies[buyer];
        if (!p.exists) revert NoPolicy();
        if (block.timestamp > p.expiry) revert PolicyExpired();
        if (amount > p.maxPerPayment) revert ExceedsPerPaymentCap();
        if (uint256(p.spent) + amount > p.budget) revert ExceedsBudget();
        if (p.useAllowlist && !allowedSeller[buyer][seller]) revert SellerNotAllowed();

        p.spent += amount.toUint128();
        emit BudgetConsumed(buyer, seller, amount, p.spent);
        return p.requireBonded;
    }
}
