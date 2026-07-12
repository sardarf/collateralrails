// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BondedRegistry} from "./BondedRegistry.sol";
import {PolicyManager} from "./PolicyManager.sol";

/// @title SettlementRouter
/// @notice Simulated x402-shaped payment rail. Buyer prefunds a spending
///         balance; the agent pays; funds move to the SELLER IMMEDIATELY.
///         Nothing is escrowed per call — assurance comes from the seller's
///         performance bond in the BondedRegistry. The payment record exists
///         only to anchor dual delivery attestations and claims.
/// @dev    The status machine is driven exclusively by the ClaimManager, which
///         owns dual-attestation verification. Status transitions here never
///         make trust decisions on their own — they only record state and move
///         collateral exposure.
contract SettlementRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Payment lifecycle. Time-derived conditions ("evidence incomplete",
    ///         "claimable") are computed off these stored states plus deadlines;
    ///         no stored status is overloaded with two meanings.
    enum Status {
        None,
        Settled,            // paid, awaiting delivery attestations
        SellerAttested,     // seller anchored an on-time attestation; buyer has not
        BuyerAttested,      // buyer anchored an on-time attestation; seller has not
        DeliveryConfirmed,  // both attested on time AND response hashes matched
        HashMismatch,       // both attested on time but hashes differ — not confirmed
        Claimed,            // included in an open batch claim
        Refunded,           // claim resolved against seller; buyer refunded from bond
        Released            // claim window expired unclaimed, or defended out of a claim
    }

    struct Payment {
        address buyer;
        address seller;
        uint128 amount;
        bytes32 requestHash;
        uint64 settledAt;
        uint64 receiptDeadline; // attestations must be anchored on or before this
        Status status;
    }

    IERC20 public immutable TOKEN;
    BondedRegistry public immutable REGISTRY;
    PolicyManager public immutable POLICY;
    uint256 public immutable RECEIPT_WINDOW; // both parties must attest within
    uint256 public immutable CLAIM_WINDOW; // watchers may claim within, after deadline

    address public claimManager;
    address public deployer;

    uint256 public nextPaymentId = 1;
    mapping(uint256 => Payment) public payments;
    mapping(address => uint256) public balanceOf; // buyer spending balances
    /// @notice buyer => agent => approved. Minimal bounded-agency wiring: the
    ///         agent never holds the buyer's key; it spends the buyer's router
    ///         balance under the buyer's POLICY.
    mapping(address => mapping(address => bool)) public approvedAgent;
    /// @notice paymentId => agent that initiated it (0x0 = buyer paid directly)
    mapping(uint256 => address) public agentOf;

    event Deposited(address indexed buyer, uint256 amount, uint256 balance);
    event Withdrawn(address indexed buyer, uint256 amount, uint256 balance);
    event PaymentSettled(
        uint256 indexed paymentId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        bytes32 requestHash,
        uint64 receiptDeadline
    );
    event PaymentStatusChanged(uint256 indexed paymentId, Status status);
    event AgentApproved(address indexed buyer, address indexed agent, bool approved);
    event PaidByAgent(uint256 indexed paymentId, address indexed agent);

    error NotApprovedAgent();
    error NotClaimManager();
    error InsufficientBalance();
    error SellerNotBonded();
    error InvalidStatus();
    error ClaimWindowStillOpen();
    error AlreadyWired();

    modifier onlyClaimManager() {
        _onlyClaimManager();
        _;
    }

    function _onlyClaimManager() internal view {
        if (msg.sender != claimManager) revert NotClaimManager();
    }

    constructor(IERC20 _token, BondedRegistry _registry, PolicyManager _policy, uint256 _receiptWindow, uint256 _claimWindow) {
        TOKEN = _token;
        REGISTRY = _registry;
        POLICY = _policy;
        RECEIPT_WINDOW = _receiptWindow;
        CLAIM_WINDOW = _claimWindow;
        deployer = msg.sender;
    }

    function wire(address _claimManager) external {
        if (msg.sender != deployer || claimManager != address(0)) revert AlreadyWired();
        claimManager = _claimManager;
    }

    // ---------------------------------------------------------------- buyers

    function deposit(uint256 amount) external nonReentrant {
        TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        emit Deposited(msg.sender, amount, balanceOf[msg.sender]);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        TOKEN.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, balanceOf[msg.sender]);
    }

    /// @notice Buyer grants/revokes an agent's right to spend the buyer's
    ///         router balance under the buyer's own POLICY.
    function approveAgent(address agent, bool approved) external {
        approvedAgent[msg.sender][agent] = approved;
        emit AgentApproved(msg.sender, agent, approved);
    }

    /// @notice The x402-shaped call: instant settlement to the seller, bound
    ///         to a request commitment, creating a dual-attestation obligation.
    function pay(address seller, uint256 amount, bytes32 requestHash)
        external
        nonReentrant
        returns (uint256 paymentId)
    {
        return _pay(msg.sender, seller, amount, requestHash);
    }

    /// @notice Agent path: pays on behalf of an approving buyer. Funds come
    ///         from the buyer's balance; budget is consumed from the buyer's
    ///         POLICY; refunds (if slashed) go to the buyer.
    function payForBuyer(address buyer, address seller, uint256 amount, bytes32 requestHash)
        external
        nonReentrant
        returns (uint256 paymentId)
    {
        if (!approvedAgent[buyer][msg.sender]) revert NotApprovedAgent();
        paymentId = _pay(buyer, seller, amount, requestHash);
        agentOf[paymentId] = msg.sender;
        emit PaidByAgent(paymentId, msg.sender);
    }

    function _pay(address buyer, address seller, uint256 amount, bytes32 requestHash)
        internal
        returns (uint256 paymentId)
    {
        if (balanceOf[buyer] < amount) revert InsufficientBalance();

        // POLICY check + budget consumption (CEI: consume before transfer)
        bool requireBonded = POLICY.checkAndConsume(buyer, seller, amount);
        if (requireBonded && !REGISTRY.isActive(seller)) revert SellerNotBonded();

        // exposure invariant: reverts if exposure would exceed bond,
        // and reverts if seller is inactive/delisted.
        REGISTRY.onPayment(seller, amount);

        balanceOf[buyer] -= amount;
        TOKEN.safeTransfer(seller, amount); // instant settlement — no escrow

        paymentId = nextPaymentId++;
        uint64 deadline = (block.timestamp + RECEIPT_WINDOW).toUint64();
        payments[paymentId] = Payment({
            buyer: buyer,
            seller: seller,
            amount: amount.toUint128(),
            requestHash: requestHash,
            settledAt: block.timestamp.toUint64(),
            receiptDeadline: deadline,
            status: Status.Settled
        });

        emit PaymentSettled(paymentId, buyer, seller, amount, requestHash, deadline);
    }

    // ------------------------------------------------------------- lifecycle
    // All transitions are ClaimManager-controlled; it owns attestation logic.

    /// @notice First on-time attestation recorded. `sellerSide` picks which
    ///         party attested; the payment must still be awaiting evidence.
    function markAttested(uint256 paymentId, bool sellerSide) external onlyClaimManager {
        Payment storage p = payments[paymentId];
        if (p.status != Status.Settled) revert InvalidStatus();
        p.status = sellerSide ? Status.SellerAttested : Status.BuyerAttested;
        emit PaymentStatusChanged(paymentId, p.status);
    }

    /// @notice Both parties attested on time and the response hashes matched.
    ///         Exposure is released and the seller earns a confirmed delivery.
    function confirmDelivery(uint256 paymentId) external onlyClaimManager {
        Payment storage p = payments[paymentId];
        if (p.status != Status.SellerAttested && p.status != Status.BuyerAttested) revert InvalidStatus();
        p.status = Status.DeliveryConfirmed;
        REGISTRY.releaseExposure(p.seller, p.amount);
        REGISTRY.onConfirmed(p.seller);
        emit PaymentStatusChanged(paymentId, Status.DeliveryConfirmed);
    }

    /// @notice Both parties attested on time but disagreed on the delivered
    ///         bytes. Not a confirmed delivery; exposure stays until resolved.
    function markMismatch(uint256 paymentId) external onlyClaimManager {
        Payment storage p = payments[paymentId];
        if (p.status != Status.SellerAttested && p.status != Status.BuyerAttested) revert InvalidStatus();
        p.status = Status.HashMismatch;
        emit PaymentStatusChanged(paymentId, Status.HashMismatch);
    }

    /// @notice Included in an open claim. Only claimable pre-states qualify:
    ///         payments that never reached a confirmed delivery.
    function markClaimed(uint256 paymentId) external onlyClaimManager {
        Payment storage p = payments[paymentId];
        if (
            p.status != Status.Settled && p.status != Status.SellerAttested
                && p.status != Status.BuyerAttested && p.status != Status.HashMismatch
        ) revert InvalidStatus();
        p.status = Status.Claimed;
        emit PaymentStatusChanged(paymentId, Status.Claimed);
    }

    /// @notice A claimed payment defended out of the claim (seller committed
    ///         valid on-time evidence). Exposure is freed; no slash.
    function markReleased(uint256 paymentId) external onlyClaimManager {
        Payment storage p = payments[paymentId];
        if (p.status != Status.Claimed) revert InvalidStatus();
        p.status = Status.Released;
        REGISTRY.releaseExposure(p.seller, p.amount);
        emit PaymentStatusChanged(paymentId, Status.Released);
    }

    function markRefunded(uint256 paymentId) external onlyClaimManager {
        Payment storage p = payments[paymentId];
        if (p.status != Status.Claimed) revert InvalidStatus();
        p.status = Status.Refunded;
        emit PaymentStatusChanged(paymentId, Status.Refunded);
    }

    /// @notice Permissionless capacity recycling: once the claim window has
    ///         expired with no claim, the seller's exposure for this payment
    ///         is freed. Applies to any payment that never confirmed delivery
    ///         and was never claimed. Preserves the watchers' claim period.
    function releaseExpired(uint256 paymentId) external {
        Payment storage p = payments[paymentId];
        if (
            p.status != Status.Settled && p.status != Status.SellerAttested
                && p.status != Status.BuyerAttested && p.status != Status.HashMismatch
        ) revert InvalidStatus();
        if (block.timestamp <= uint256(p.receiptDeadline) + CLAIM_WINDOW) revert ClaimWindowStillOpen();
        p.status = Status.Released;
        REGISTRY.releaseExposure(p.seller, p.amount);
        emit PaymentStatusChanged(paymentId, Status.Released);
    }

    function getPayment(uint256 paymentId) external view returns (Payment memory) {
        return payments[paymentId];
    }
}