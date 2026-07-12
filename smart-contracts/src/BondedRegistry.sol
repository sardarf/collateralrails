// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title BondedRegistry
/// @notice Seller performance-bond custody + public registry + reputation.
///         Refunds to buyers are paid FROM THE SELLER'S PERFORMANCE BOND.
///         Buyer funds are never escrowed here.
/// @dev Core invariant: a seller's open unreceipted exposure never exceeds
///      its bond, enforced at payment time by `onPayment`.
contract BondedRegistry is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct Seller {
        uint128 bond; // staked collateral (mUSDC)
        uint128 openExposure; // settled, unreceipted, refundable amount
        uint64 registeredAt;
        uint64 withdrawAfter; // 0 = no withdrawal requested
        uint32 served; // payments settled to this seller
        uint32 confirmed; // payments with a matching dual delivery attestation
        uint32 failed; // payments proven failed (slashed)
        uint32 openClaims; // claims currently pending against seller
        uint128 slashedTotal;
        bool active; // listed & accepting payments
        bool exists;
        bool endpointVerified; // verifier confirmed the seller controls `endpoint`
        string handle; // globally-unique display name (anti-impersonation)
        string endpoint; // service endpoint URL (verified against .well-known)
    }

    IERC20 public immutable TOKEN;
    uint256 public immutable MIN_BOND;
    uint256 public immutable WITHDRAW_COOLDOWN;
    /// @notice failure ratio (bps of served) above which a seller is delisted
    uint256 public immutable MAX_FAIL_BPS;
    uint256 public constant BPS = 10_000;

    /// @notice Reputation tiers (returned by `reputation`). New sellers start at
    ///         NEW regardless of deposit — reputation is earned, never bought.
    uint8 public constant TIER_NEW = 0;
    uint8 public constant TIER_BUILDING = 1;
    uint8 public constant TIER_ESTABLISHED = 2;
    uint8 public constant TIER_TRUSTED = 3;
    uint8 public constant TIER_FLAGGED = 4;

    address public router;
    address public claimManager;
    /// @notice trusted oracle allowed to attest endpoint ownership (the watcher).
    address public verifier;

    mapping(address => Seller) internal sellers;
    address[] public sellerList;
    /// @notice keccak256(lowercased handle) => owning seller. Enforces uniqueness.
    mapping(bytes32 => address) public handleOwner;

    event SellerRegistered(address indexed seller, uint256 bond, string handle, string endpoint);
    event VerifierUpdated(address indexed verifier);
    event EndpointVerified(address indexed seller, string endpoint);
    event BondToppedUp(address indexed seller, uint256 amount, uint256 newBond);
    event WithdrawalRequested(address indexed seller, uint64 withdrawAfter);
    event WithdrawalExecuted(address indexed seller, uint256 amount);
    event SellerSlashed(
        address indexed seller,
        uint256 refundTotal,
        uint256 penalty,
        uint32 failures,
        uint256 remainingBond
    );
    event SellerDelisted(address indexed seller, string reason);
    event SellerRelisted(address indexed seller);
    event ReputationUpdated(address indexed seller, uint32 served, uint32 failed, uint256 bond);
    event ExposureChanged(address indexed seller, uint256 openExposure);
    event DeliveryConfirmed(address indexed seller, uint32 confirmed);

    error NotAuthorized();
    error AlreadyRegistered();
    error NotRegistered();
    error BondTooLow();
    error HandleTaken();
    error InvalidHandle();
    error SellerInactive();
    error ExposureExceedsBond();
    error CooldownActive();
    error OpenClaimsExist();
    error OpenExposureExists();
    error NoWithdrawalRequested();

    modifier onlyRouter() {
        _onlyRouter();
        _;
    }

    modifier onlyClaimManager() {
        _onlyClaimManager();
        _;
    }

    function _onlyRouter() internal view {
        if (msg.sender != router) revert NotAuthorized();
    }

    function _onlyClaimManager() internal view {
        if (msg.sender != claimManager) revert NotAuthorized();
    }

    constructor(IERC20 _token, uint256 _minBond, uint256 _withdrawCooldown, uint256 _maxFailBps)
        Ownable(msg.sender)
    {
        TOKEN = _token;
        MIN_BOND = _minBond;
        WITHDRAW_COOLDOWN = _withdrawCooldown;
        MAX_FAIL_BPS = _maxFailBps;
    }

    /// @notice one-time wiring; renounce-style: can only be set once.
    function wire(address _router, address _claimManager) external onlyOwner {
        require(router == address(0) && claimManager == address(0), "wired");
        router = _router;
        claimManager = _claimManager;
    }

    /// @notice Set the trusted endpoint-ownership oracle (the watcher). Owner-only.
    function setVerifier(address _verifier) external onlyOwner {
        verifier = _verifier;
        emit VerifierUpdated(_verifier);
    }

    // ---------------------------------------------------------------- sellers

    /// @param handle   globally-unique display name — reverts if already claimed.
    /// @param endpoint service URL the verifier later attests ownership of.
    function register(uint256 bondAmount, string calldata handle, string calldata endpoint)
        external
        nonReentrant
    {
        Seller storage s = sellers[msg.sender];
        if (s.exists) revert AlreadyRegistered();
        if (bondAmount < MIN_BOND) revert BondTooLow();

        bytes32 hk = _handleKey(handle); // reverts InvalidHandle on empty/oversized
        if (handleOwner[hk] != address(0)) revert HandleTaken();

        TOKEN.safeTransferFrom(msg.sender, address(this), bondAmount);

        s.exists = true;
        s.active = true;
        s.bond = bondAmount.toUint128();
        s.registeredAt = block.timestamp.toUint64();
        s.handle = handle;
        s.endpoint = endpoint;
        handleOwner[hk] = msg.sender;
        sellerList.push(msg.sender);

        emit SellerRegistered(msg.sender, bondAmount, handle, endpoint);
    }

    /// @notice Oracle attestation that `seller` provably controls its endpoint
    ///         (e.g. serves /.well-known/collateralrails.json with its address).
    function verifyEndpoint(address seller) external {
        if (msg.sender != verifier) revert NotAuthorized();
        Seller storage s = sellers[seller];
        if (!s.exists) revert NotRegistered();
        s.endpointVerified = true;
        emit EndpointVerified(seller, s.endpoint);
    }

    /// @notice Normalise + validate a handle. Lowercases ASCII so "Weather" and
    ///         "weather" collide; enforces 1..64 bytes.
    function _handleKey(string calldata handle) internal pure returns (bytes32) {
        bytes memory b = bytes(handle);
        if (b.length == 0 || b.length > 64) revert InvalidHandle();
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 65 && c <= 90) b[i] = bytes1(c + 32); // A-Z -> a-z
        }
        return keccak256(b);
    }

    function topUp(uint256 amount) external nonReentrant {
        Seller storage s = sellers[msg.sender];
        if (!s.exists) revert NotRegistered();
        TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        s.bond += amount.toUint128();
        // relist if seller restored bond above minimum and is not withdrawal-locked
        if (!s.active && s.bond >= MIN_BOND && s.withdrawAfter == 0 && !_failRatioBreached(s)) {
            s.active = true;
            emit SellerRelisted(msg.sender);
        }
        emit BondToppedUp(msg.sender, amount, s.bond);
    }

    /// @notice Requesting withdrawal immediately stops new payments (deactivates listing).
    function requestWithdrawal() external {
        Seller storage s = sellers[msg.sender];
        if (!s.exists) revert NotRegistered();
        s.withdrawAfter = (block.timestamp + WITHDRAW_COOLDOWN).toUint64();
        if (s.active) {
            s.active = false;
            emit SellerDelisted(msg.sender, "withdrawal requested");
        }
        emit WithdrawalRequested(msg.sender, s.withdrawAfter);
    }

    /// @notice Withdrawal executes only after cooldown, with no open claims and
    ///         no open unreceipted exposure — closing the exit-before-slash attack.
    function executeWithdrawal() external nonReentrant {
        Seller storage s = sellers[msg.sender];
        if (!s.exists) revert NotRegistered();
        if (s.withdrawAfter == 0) revert NoWithdrawalRequested();
        if (block.timestamp < s.withdrawAfter) revert CooldownActive();
        if (s.openClaims != 0) revert OpenClaimsExist();
        if (s.openExposure != 0) revert OpenExposureExists();

        uint256 amount = s.bond;
        s.bond = 0;
        s.withdrawAfter = 0;
        TOKEN.safeTransfer(msg.sender, amount);
        emit WithdrawalExecuted(msg.sender, amount);
    }

    // ------------------------------------------------------------ router hooks

    /// @notice Called on every settlement. Enforces exposure <= bond.
    function onPayment(address seller, uint256 amount) external onlyRouter {
        Seller storage s = sellers[seller];
        if (!s.exists || !s.active) revert SellerInactive();
        if (uint256(s.openExposure) + amount > s.bond) revert ExposureExceedsBond();
        s.openExposure += amount.toUint128();
        s.served += 1;
        emit ExposureChanged(seller, s.openExposure);
        emit ReputationUpdated(seller, s.served, s.failed, s.bond);
    }

    /// @notice Records a dual-confirmed delivery (both parties attested the same
    ///         response bytes on time). Router-only; called alongside exposure
    ///         release when a payment reaches DeliveryConfirmed.
    function onConfirmed(address seller) external onlyRouter {
        Seller storage s = sellers[seller];
        s.confirmed += 1;
        emit DeliveryConfirmed(seller, s.confirmed);
    }

    /// @notice Exposure release on delivery confirmation, defended claim, claim
    ///         resolution, or expiry of the claim window (router/claimManager).
    function releaseExposure(address seller, uint256 amount) external {
        if (msg.sender != router && msg.sender != claimManager) revert NotAuthorized();
        Seller storage s = sellers[seller];
        uint128 a = amount.toUint128();
        s.openExposure = a >= s.openExposure ? 0 : s.openExposure - a;
        emit ExposureChanged(seller, s.openExposure);
    }

    // ------------------------------------------------------ claimManager hooks

    function incOpenClaims(address seller) external onlyClaimManager {
        sellers[seller].openClaims += 1;
    }

    function decOpenClaims(address seller) external onlyClaimManager {
        Seller storage s = sellers[seller];
        if (s.openClaims > 0) s.openClaims -= 1;
    }

    /// @notice Executes a resolved claim: refunds buyers from the seller bond,
    ///         pays penalty shares, updates reputation, delists chronic offenders.
    function slash(
        address seller,
        address[] calldata buyers,
        uint256[] calldata refunds,
        uint256 refundTotal,
        uint256 watcherPenalty,
        address watcher,
        uint256 treasuryPenalty,
        address treasury
    ) external onlyClaimManager nonReentrant {
        Seller storage s = sellers[seller];
        uint256 totalDebit = refundTotal + watcherPenalty + treasuryPenalty;
        // bond depletion floor: never debit more than the bond
        if (totalDebit > s.bond) {
            // pro-rata is overkill for MVP: refunds are always collateralised by
            // the exposure invariant; penalties absorb any shortfall.
            uint256 available = s.bond;
            uint256 penaltyBudget = available > refundTotal ? available - refundTotal : 0;
            if (watcherPenalty + treasuryPenalty > penaltyBudget) {
                watcherPenalty = penaltyBudget;
                treasuryPenalty = 0;
            }
            totalDebit = refundTotal + watcherPenalty + treasuryPenalty;
        }

        s.bond -= totalDebit.toUint128();
        s.slashedTotal += refundTotal.toUint128();
        s.failed += buyers.length.toUint32();
        s.openExposure =
            refundTotal.toUint128() >= s.openExposure ? 0 : s.openExposure - refundTotal.toUint128();

        for (uint256 i = 0; i < buyers.length; i++) {
            TOKEN.safeTransfer(buyers[i], refunds[i]);
        }
        if (watcherPenalty > 0) TOKEN.safeTransfer(watcher, watcherPenalty);
        if (treasuryPenalty > 0) TOKEN.safeTransfer(treasury, treasuryPenalty);

        emit SellerSlashed(seller, refundTotal, watcherPenalty + treasuryPenalty, buyers.length.toUint32(), s.bond);
        emit ReputationUpdated(seller, s.served, s.failed, s.bond);
        emit ExposureChanged(seller, s.openExposure);

        if (s.active && (s.bond < MIN_BOND || _failRatioBreached(s))) {
            s.active = false;
            emit SellerDelisted(seller, s.bond < MIN_BOND ? "bond below minimum" : "failure ratio breached");
        }
    }

    /// @notice Pays a forfeited claim stake to the seller (false-claim penalty).
    function payTo(address to, uint256 amount) external onlyClaimManager nonReentrant {
        TOKEN.safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------- views

    function _failRatioBreached(Seller storage s) internal view returns (bool) {
        if (s.served == 0) return false;
        return (uint256(s.failed) * BPS) / s.served > MAX_FAIL_BPS;
    }

    function isActive(address seller) external view returns (bool) {
        Seller storage s = sellers[seller];
        return s.exists && s.active;
    }

    function getSeller(address seller)
        external
        view
        returns (
            uint256 bond,
            uint256 openExposure,
            uint32 served,
            uint32 failed,
            uint32 openClaims,
            uint256 slashedTotal,
            bool active,
            string memory endpoint,
            uint32 confirmed
        )
    {
        Seller storage s = sellers[seller];
        if (!s.exists) revert NotRegistered();
        return (s.bond, s.openExposure, s.served, s.failed, s.openClaims, s.slashedTotal, s.active, s.endpoint, s.confirmed);
    }

    /// @notice Identity signals used to fight impersonation:
    ///         a globally-unique handle plus an oracle-attested endpoint.
    function identity(address seller)
        external
        view
        returns (string memory handle, string memory endpoint, bool endpointVerified)
    {
        Seller storage s = sellers[seller];
        if (!s.exists) revert NotRegistered();
        return (s.handle, s.endpoint, s.endpointVerified);
    }

    /// @notice On-chain reputation derived purely from delivery performance.
    ///         `score` is 0..1000. Deposit is intentionally excluded so
    ///         reputation cannot be bought — a fresh sybil is always TIER_NEW.
    /// @return score   0..1000 composite of reliability, volume and age.
    /// @return tier    TIER_NEW..TIER_FLAGGED.
    /// @return flagged true if the seller has ever been slashed or breaches the
    ///                 failure-ratio limit.
    function reputation(address seller)
        external
        view
        returns (uint16 score, uint8 tier, bool flagged)
    {
        Seller storage s = sellers[seller];
        if (!s.exists) return (0, TIER_NEW, false);

        flagged = s.slashedTotal > 0 || _failRatioBreached(s);

        if (s.served == 0) {
            // No confirmed activity yet — unproven regardless of stake.
            return (0, flagged ? TIER_FLAGGED : TIER_NEW, flagged);
        }

        // Confirmed deliveries = served payments not later proven failed.
        uint256 success = s.served > s.failed ? s.served - s.failed : 0;

        // Reliability: share of served payments that were delivered (0..500).
        uint256 relScore = (success * 10_000 / s.served) * 500 / 10_000;
        // Volume: confirmed deliveries, saturating at 200 (0..400).
        uint256 vol = success > 200 ? 200 : success;
        uint256 volScore = vol * 2;
        // Longevity: days in the registry, saturating at 100 (0..100).
        uint256 ageDays = (block.timestamp - s.registeredAt) / 1 days;
        uint256 ageScore = ageDays > 100 ? 100 : ageDays;

        uint256 raw = relScore + volScore + ageScore; // 0..1000
        // A slashing history caps trust: apply a 40% haircut.
        if (flagged) raw = raw * 6 / 10;

        score = raw.toUint16();
        if (flagged) tier = TIER_FLAGGED;
        else if (score >= 750) tier = TIER_TRUSTED;
        else if (score >= 450) tier = TIER_ESTABLISHED;
        else tier = TIER_BUILDING;
    }

    function sellerCount() external view returns (uint256) {
        return sellerList.length;
    }
}
