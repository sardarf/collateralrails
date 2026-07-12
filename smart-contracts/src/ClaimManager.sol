// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BondedRegistry} from "./BondedRegistry.sol";
import {SettlementRouter} from "./SettlementRouter.sol";
import {ReceiptLib} from "./ReceiptLib.sol";

/// @title ClaimManager
/// @notice Owns dual delivery attestation and defended batch claims.
///
///   Attestation (happy path):
///     - Both the seller AND the buyer independently sign an EIP-712 commitment
///       to the delivered response bytes and anchor it ON-CHAIN before the
///       payment's receipt deadline.
///     - When both are anchored on time and `sellerHash == buyerHash`, the
///       payment is DELIVERY CONFIRMED: exposure released, delivery recorded.
///     - Matching hashes prove the two parties agree on the same response bytes.
///       They do NOT prove semantic correctness/quality (out of scope).
///
///   Claims (failure path):
///     - Watchers aggregate deadline-expired, unconfirmed payments against one
///       seller into a single batch claim, posting a claim stake.
///     - The seller gets a defense window. A payment is defensible ONLY from
///       evidence the seller COMMITTED ON TIME: an on-chain seller attestation
///       anchored on or before the receipt deadline, with no contradicting
///       buyer attestation. There is no way to fabricate or backdate a defense
///       after a claim is filed — the defense reads only pre-committed on-chain
///       state, never a freshly supplied signature.
///     - Surviving items slash the seller bond: buyers refunded, watcher bounty
///       paid, reputation updated. A fully defended claim forfeits the watcher's
///       stake to the seller (griefing deterrent).
contract ClaimManager is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ReceiptLib for ReceiptLib.Attestation;
    using SafeCast for uint256;

    /// @dev On-chain record of one party's attestation. `at` is the block
    ///      timestamp when it was anchored — the authoritative, unforgeable
    ///      delivery-evidence timestamp.
    struct Att {
        bytes32 responseHash;
        uint64 at;
    }

    struct Claim {
        address watcher;
        address seller;
        uint128 refundTotal; // refunds still live in this claim
        uint128 stake;
        uint64 defenseEnd;
        bool resolved;
        uint32 defendedCount;
        uint256[] paymentIds;
    }

    IERC20 public immutable TOKEN;
    BondedRegistry public immutable REGISTRY;
    SettlementRouter public immutable ROUTER;
    address public immutable TREASURY;

    uint256 public immutable MIN_BATCH; // min failures to aggregate
    uint256 public immutable HIGH_VALUE_THRESHOLD; // single-payment claim floor
    uint256 public immutable DEFENSE_WINDOW;
    uint256 public immutable PENALTY_BPS; // penalty on refundTotal
    uint256 public immutable WATCHER_SHARE_BPS; // watcher share of penalty
    uint256 public immutable CLAIM_STAKE_BPS; // stake as bps of refundTotal
    uint256 public immutable CLAIM_STAKE_FLOOR;
    uint256 public constant BPS = 10_000;

    uint256 public nextClaimId = 1;
    mapping(uint256 => Claim) internal claims;
    // paymentId => claimId it is included in (0 = none)
    mapping(uint256 => uint256) public claimOf;
    // paymentId => committed attestations (public for frontend transaction timeline)
    mapping(uint256 => Att) public sellerAtt;
    mapping(uint256 => Att) public buyerAtt;

    event AttestationAnchored(
        uint256 indexed paymentId, address indexed signer, bool sellerSide, bytes32 responseHash
    );
    event ClaimFiled(
        uint256 indexed claimId, address indexed seller, address indexed watcher, uint256 count, uint256 refundTotal, uint64 defenseEnd
    );
    event ItemDefended(uint256 indexed claimId, uint256 indexed paymentId);
    event ClaimResolved(
        uint256 indexed claimId, uint256 refunded, uint256 slashedPenalty, uint32 defended, uint32 failed
    );
    event FalseClaimPenalised(uint256 indexed claimId, address indexed watcher, uint256 stakeForfeited);

    error BatchTooSmall();
    error PaymentNotClaimable();
    error WrongSeller();
    error DeadlineNotPassed();
    error ClaimWindowClosed();
    error DefenseWindowOver();
    error DefenseWindowOpen();
    error AlreadyResolved();
    error InvalidAttestation();
    error AttestationWindowClosed();
    error AlreadyAttested();
    error NotAttestable();
    error NotInClaim();
    error NotDefensible();

    constructor(
        IERC20 _token,
        BondedRegistry _registry,
        SettlementRouter _router,
        address _treasury,
        uint256 _minBatch,
        uint256 _highValueThreshold,
        uint256 _defenseWindow,
        uint256 _penaltyBps,
        uint256 _watcherShareBps,
        uint256 _claimStakeBps,
        uint256 _claimStakeFloor
    ) EIP712("CollateralRails", "1") {
        TOKEN = _token;
        REGISTRY = _registry;
        ROUTER = _router;
        TREASURY = _treasury;
        MIN_BATCH = _minBatch;
        HIGH_VALUE_THRESHOLD = _highValueThreshold;
        DEFENSE_WINDOW = _defenseWindow;
        PENALTY_BPS = _penaltyBps;
        WATCHER_SHARE_BPS = _watcherShareBps;
        CLAIM_STAKE_BPS = _claimStakeBps;
        CLAIM_STAKE_FLOOR = _claimStakeFloor;
    }

    // ---------------------------------------------------------- attestations

    function attestationDigest(ReceiptLib.Attestation memory a) public view returns (bytes32) {
        return _hashTypedDataV4(a.hashStruct());
    }

    /// @notice Anchor a signed delivery attestation on-chain. Accepts a valid
    ///         signature from EITHER the payment's seller or its buyer; the
    ///         recovered signer decides which side it counts as.
    ///
    ///         The submission itself must land on or before the receipt deadline
    ///         (`block.timestamp <= receiptDeadline`). Because the timestamp of
    ///         record is the on-chain anchor time — not a self-reported field —
    ///         an attestation cannot be backdated or produced after the fact.
    ///
    ///         When both sides are anchored on time, hashes are compared:
    ///         equal → DeliveryConfirmed; differ → HashMismatch.
    function attest(ReceiptLib.Attestation calldata a, bytes calldata sig) external {
        uint256 pid = a.paymentId;
        SettlementRouter.Payment memory p = ROUTER.getPayment(pid);

        // Only payments still gathering evidence can be attested.
        if (
            p.status != SettlementRouter.Status.Settled
                && p.status != SettlementRouter.Status.SellerAttested
                && p.status != SettlementRouter.Status.BuyerAttested
        ) revert NotAttestable();
        if (a.requestHash != p.requestHash) revert InvalidAttestation();
        // On-time anchoring is the core anti-fabrication guarantee.
        if (block.timestamp > p.receiptDeadline) revert AttestationWindowClosed();

        address signer = ECDSA.recover(attestationDigest(a), sig);
        bool sellerSide;
        if (signer == p.seller) sellerSide = true;
        else if (signer == p.buyer) sellerSide = false;
        else revert InvalidAttestation();

        Att storage self = sellerSide ? sellerAtt[pid] : buyerAtt[pid];
        Att storage other = sellerSide ? buyerAtt[pid] : sellerAtt[pid];
        if (self.at != 0) revert AlreadyAttested();

        self.responseHash = a.responseHash;
        self.at = uint64(block.timestamp);
        emit AttestationAnchored(pid, signer, sellerSide, a.responseHash);

        if (other.at == 0) {
            // first attestation on this payment
            ROUTER.markAttested(pid, sellerSide);
        } else if (other.responseHash == a.responseHash) {
            ROUTER.confirmDelivery(pid);
        } else {
            ROUTER.markMismatch(pid);
        }
    }

    // ---------------------------------------------------------------- claims

    /// @notice Watcher aggregates deadline-expired, unconfirmed payments against
    ///         one seller into a single claim, staking against false claims.
    function fileClaim(address seller, uint256[] calldata paymentIds)
        external
        nonReentrant
        returns (uint256 claimId)
    {
        uint256 n = paymentIds.length;
        uint256 refundTotal;

        for (uint256 i = 0; i < n; i++) {
            SettlementRouter.Payment memory p = ROUTER.getPayment(paymentIds[i]);
            if (p.seller != seller) revert WrongSeller();
            // Delivery-confirmed payments are terminal and can never be claimed.
            if (
                p.status != SettlementRouter.Status.Settled
                    && p.status != SettlementRouter.Status.SellerAttested
                    && p.status != SettlementRouter.Status.BuyerAttested
                    && p.status != SettlementRouter.Status.HashMismatch
            ) revert PaymentNotClaimable();
            if (block.timestamp <= p.receiptDeadline) revert DeadlineNotPassed();
            if (block.timestamp > uint256(p.receiptDeadline) + ROUTER.CLAIM_WINDOW()) revert ClaimWindowClosed();
            refundTotal += p.amount;
        }
        if (n < MIN_BATCH && refundTotal < HIGH_VALUE_THRESHOLD) revert BatchTooSmall();

        uint256 stake = (refundTotal * CLAIM_STAKE_BPS) / BPS;
        if (stake < CLAIM_STAKE_FLOOR) stake = CLAIM_STAKE_FLOOR;
        TOKEN.safeTransferFrom(msg.sender, address(this), stake);

        claimId = nextClaimId++;
        Claim storage c = claims[claimId];
        c.watcher = msg.sender;
        c.seller = seller;
        c.refundTotal = refundTotal.toUint128();
        c.stake = stake.toUint128();
        c.defenseEnd = (block.timestamp + DEFENSE_WINDOW).toUint64();
        c.paymentIds = paymentIds;

        for (uint256 i = 0; i < n; i++) {
            ROUTER.markClaimed(paymentIds[i]);
            claimOf[paymentIds[i]] = claimId;
        }
        REGISTRY.incOpenClaims(seller);

        emit ClaimFiled(claimId, seller, msg.sender, n, refundTotal, c.defenseEnd);
    }

    /// @notice Seller due process. A payment is knocked out of the claim ONLY if
    ///         the seller committed valid evidence ON TIME: an on-chain seller
    ///         attestation anchored on or before the receipt deadline, and no
    ///         contradicting on-time buyer attestation. No signature is accepted
    ///         here — the defense consults only pre-committed on-chain state, so
    ///         a late-fabricated attestation is impossible.
    function defend(uint256 claimId, uint256[] calldata paymentIds) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.resolved) revert AlreadyResolved();
        if (block.timestamp > c.defenseEnd) revert DefenseWindowOver();

        for (uint256 i = 0; i < paymentIds.length; i++) {
            uint256 pid = paymentIds[i];
            if (claimOf[pid] != claimId) revert NotInClaim();
            SettlementRouter.Payment memory p = ROUTER.getPayment(pid);
            if (p.status != SettlementRouter.Status.Claimed) revert PaymentNotClaimable();
            if (!_defensible(pid, p.receiptDeadline)) revert NotDefensible();

            ROUTER.markReleased(pid); // Claimed -> Released, frees exposure
            claimOf[pid] = 0;
            c.refundTotal -= p.amount;
            c.defendedCount += 1;
            emit ItemDefended(claimId, pid);
        }
    }

    /// @dev Defensible iff the seller anchored an attestation on time and the
    ///      buyer did not anchor a contradicting one. Reading only committed
    ///      state makes late fabrication impossible.
    function _defensible(uint256 pid, uint64 receiptDeadline) internal view returns (bool) {
        Att storage s = sellerAtt[pid];
        if (s.at == 0 || s.at > receiptDeadline) return false; // no on-time seller evidence
        Att storage b = buyerAtt[pid];
        if (b.at != 0 && b.responseHash != s.responseHash) return false; // buyer contradicts
        return true;
    }

    /// @notice After the defense window: slash survivors, refund buyers from
    ///         the seller bond, pay the watcher bounty — or, if fully
    ///         defended, forfeit the watcher's stake to the seller.
    function resolve(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.resolved) revert AlreadyResolved();
        if (block.timestamp <= c.defenseEnd) revert DefenseWindowOpen();
        c.resolved = true;
        REGISTRY.decOpenClaims(c.seller);

        // collect survivors
        uint256 n = c.paymentIds.length;
        uint256 survivors;
        for (uint256 i = 0; i < n; i++) {
            if (claimOf[c.paymentIds[i]] == claimId) survivors++;
        }

        if (survivors == 0) {
            // false claim: full defense — stake forfeited to the seller
            TOKEN.safeTransfer(c.seller, c.stake);
            emit FalseClaimPenalised(claimId, c.watcher, c.stake);
            emit ClaimResolved(claimId, 0, 0, c.defendedCount, 0);
            return;
        }

        address[] memory buyers = new address[](survivors);
        uint256[] memory refunds = new uint256[](survivors);
        uint256 j;
        for (uint256 i = 0; i < n; i++) {
            uint256 pid = c.paymentIds[i];
            if (claimOf[pid] != claimId) continue;
            SettlementRouter.Payment memory p = ROUTER.getPayment(pid);
            buyers[j] = p.buyer;
            refunds[j] = p.amount;
            j++;
            ROUTER.markRefunded(pid);
            claimOf[pid] = 0;
        }

        uint256 penalty = (uint256(c.refundTotal) * PENALTY_BPS) / BPS;
        uint256 watcherPenalty = (penalty * WATCHER_SHARE_BPS) / BPS;
        uint256 treasuryPenalty = penalty - watcherPenalty;

        REGISTRY.slash(
            c.seller, buyers, refunds, c.refundTotal, watcherPenalty, c.watcher, treasuryPenalty, TREASURY
        );

        // honest watcher: stake returned
        TOKEN.safeTransfer(c.watcher, c.stake);

        emit ClaimResolved(claimId, c.refundTotal, penalty, c.defendedCount, survivors.toUint32());
    }

    // ----------------------------------------------------------------- views

    function getClaim(uint256 claimId)
        external
        view
        returns (
            address watcher,
            address seller,
            uint256 refundTotal,
            uint256 stake,
            uint64 defenseEnd,
            bool resolved,
            uint32 defendedCount,
            uint256[] memory paymentIds
        )
    {
        Claim storage c = claims[claimId];
        return (c.watcher, c.seller, c.refundTotal, c.stake, c.defenseEnd, c.resolved, c.defendedCount, c.paymentIds);
    }

    /// @notice Committed dual-attestation state for a payment — powers the
    ///         frontend transaction timeline.
    function attestationOf(uint256 paymentId)
        external
        view
        returns (bytes32 sellerHash, uint64 sellerAtAt, bytes32 buyerHash, uint64 buyerAtAt)
    {
        Att storage s = sellerAtt[paymentId];
        Att storage b = buyerAtt[paymentId];
        return (s.responseHash, s.at, b.responseHash, b.at);
    }
}