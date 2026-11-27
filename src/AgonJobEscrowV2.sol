// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAgonServiceRegistry } from "./interfaces/IAgonServiceRegistry.sol";

/// @title AgonJobEscrowV2
/// @notice AgonJobEscrow with governance-controlled, timelocked protocol fees.
/// @dev Direct x402 payments never enter this contract. Existing jobs snapshot
///      the fee rate used at creation, so later governance changes are safe.
contract AgonJobEscrowV2 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1000;
    uint64 public constant PROTOCOL_FEE_CHANGE_DELAY = 2 days;
    uint64 public constant MAX_REVIEW_HOURS = 720;
    uint64 public constant MIN_REVIEW_HOURS = 1;
    /// @notice Time after a rejection in which either party may open a dispute.
    /// @dev After it passes with no dispute, the buyer can take a full refund.
    uint64 public constant REJECTION_WINDOW = 7 days;
    /// @notice Time the dispute resolver has to settle an open dispute.
    /// @dev After it passes, either party can exit and the buyer is refunded.
    uint64 public constant RESOLVER_WINDOW = 14 days;

    enum Status {
        Created,
        Accepted,
        Submitted,
        Complete,
        Rejected,
        Disputed,
        Failed
    }

    enum Settlement {
        None,
        ProviderPaid,
        BuyerRefunded
    }

    struct Job {
        uint256 jobId;
        address buyer;
        address provider;
        uint256 listingId;
        uint256 agentId;
        uint256 listingVersion;
        bytes32 manifestHash;
        bytes32 termsHash;
        bytes32 deliverableHash;
        uint256 amount;
        uint256 fee;
        uint16 feeBps;
        uint64 reviewHours;
        uint64 acceptanceDeadline;
        uint64 reviewDeadline;
        uint64 createdAt;
        uint64 submittedAt;
        Status status;
        Settlement settlement;
    }

    IERC20 public immutable usdc;
    IAgonServiceRegistry public immutable serviceRegistry;
    address public immutable disputeResolver;
    address public treasury;
    uint64 public immutable defaultReviewHours;
    uint16 public protocolFeeBps;
    uint16 public pendingProtocolFeeBps;
    uint64 public pendingProtocolFeeEffectiveAt;

    uint256 private _nextJobId = 1;
    mapping(uint256 => Job) private _jobs;
    mapping(address => mapping(bytes32 => uint256)) public jobByReference;
    /// @notice When the buyer rejected the submission. Kept outside Job so getJob stays ABI stable.
    mapping(uint256 => uint64) public rejectedAt;
    /// @notice When the dispute was opened. Kept outside Job so getJob stays ABI stable.
    mapping(uint256 => uint64) public disputedAt;
    /// @dev Paused seconds counted when each job was created. The acceptance deadline
    ///      moves forward by the paused time that accrued after this mark, because
    ///      acceptJob and submitJob cannot run while the contract is paused.
    mapping(uint256 => uint256) private _pausedMarkAtCreate;
    uint256 private _pausedSecondsTotal;
    uint64 private _pausedSince;
    /// @notice USDC owed to an address whose payout could not be sent (for example a blocklisted
    ///         address on Arc). The job still settles; the owner withdraws it with withdrawCredit.
    mapping(address => uint256) public credits;
    /// @notice Sum of all credits. Part of what the contract must hold.
    uint256 public totalCredits;

    event JobCreated(
        uint256 indexed jobId,
        bytes32 indexed clientReference,
        address indexed buyer,
        address provider,
        uint256 listingId,
        uint256 agentId,
        uint256 listingVersion,
        bytes32 manifestHash,
        bytes32 termsHash,
        uint256 amount,
        uint256 fee,
        uint16 feeBps,
        uint64 reviewHours,
        uint64 acceptanceDeadline
    );
    event JobAccepted(uint256 indexed jobId, address indexed provider);
    event JobSubmitted(uint256 indexed jobId, bytes32 indexed deliverableHash, uint64 reviewDeadline);
    event JobRejected(uint256 indexed jobId, bytes32 indexed reasonHash);
    event JobDisputed(uint256 indexed jobId, address indexed opener, bytes32 indexed reasonHash);
    event JobSettled(
        uint256 indexed jobId, Settlement settlement, address indexed recipient, uint256 amount, uint256 fee
    );
    event JobFailed(uint256 indexed jobId, address indexed caller, Settlement settlement);
    event RejectionRefundClaimed(uint256 indexed jobId, address indexed buyer, uint256 total);
    event StaleDisputeExited(uint256 indexed jobId, address indexed caller, uint256 total);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event PayoutCredited(address indexed account, uint256 amount);
    event CreditWithdrawn(address indexed account, uint256 amount);
    event RejectionAccepted(uint256 indexed jobId, address indexed provider);
    event ProtocolFeeChangeScheduled(uint256 indexed oldFeeBps, uint256 indexed newFeeBps, uint64 effectiveAt);
    event ProtocolFeeChanged(uint256 indexed oldFeeBps, uint256 indexed newFeeBps);
    event ProtocolFeeChangeCancelled(uint256 indexed pendingFeeBps, uint64 effectiveAt);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroHash();
    error InvalidReviewHours();
    error InvalidReference();
    error ListingNotEscrowEligible();
    error JobMissing();
    error NotBuyer();
    error NotProvider();
    error NotDisputeResolver();
    error InvalidStatus();
    error AcceptanceWindowOpen();
    error AcceptanceWindowClosed();
    error ReviewWindowOpen();
    error ReviewWindowClosed();
    error JobReferenceAlreadyUsed();
    error InvalidListingSnapshot();
    error FeeAboveMaximum();
    error FeeUnchanged();
    error FeeChangePending();
    error NoPendingFeeChange();
    error FeeChangeTimelocked();
    error NotParty();
    error RejectionWindowOpen();
    error RejectionWindowClosed();
    error ResolverWindowOpen();
    error ResolverWindowClosed();
    error NoCredit();

    constructor(
        address admin,
        address usdcAddress,
        address serviceRegistryAddress,
        address disputeResolverAddress,
        address treasuryAddress,
        uint64 defaultReviewHours_,
        uint16 initialProtocolFeeBps
    ) {
        if (admin == address(0) || usdcAddress == address(0) || serviceRegistryAddress == address(0)) revert ZeroAddress();
        if (disputeResolverAddress == address(0) || treasuryAddress == address(0)) revert ZeroAddress();
        _validateReviewHours(defaultReviewHours_);
        _validateProtocolFee(initialProtocolFeeBps);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        usdc = IERC20(usdcAddress);
        serviceRegistry = IAgonServiceRegistry(serviceRegistryAddress);
        disputeResolver = disputeResolverAddress;
        treasury = treasuryAddress;
        defaultReviewHours = defaultReviewHours_;
        protocolFeeBps = initialProtocolFeeBps;
    }

    /// @notice Schedule a bounded protocol fee update behind the governance delay.
    /// @dev The admin can be a DAO or multisig. Applying the change is permissionless.
    function scheduleProtocolFeeChange(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateProtocolFee(newFeeBps);
        if (pendingProtocolFeeEffectiveAt != 0) revert FeeChangePending();
        if (newFeeBps == protocolFeeBps) revert FeeUnchanged();

        uint64 effectiveAt = uint64(block.timestamp) + PROTOCOL_FEE_CHANGE_DELAY;
        pendingProtocolFeeBps = newFeeBps;
        pendingProtocolFeeEffectiveAt = effectiveAt;
        emit ProtocolFeeChangeScheduled(protocolFeeBps, newFeeBps, effectiveAt);
    }

    /// @notice Apply a scheduled fee after the timelock expires.
    function applyProtocolFeeChange() external {
        uint64 effectiveAt = pendingProtocolFeeEffectiveAt;
        if (effectiveAt == 0) revert NoPendingFeeChange();
        if (block.timestamp < effectiveAt) revert FeeChangeTimelocked();

        uint16 oldFeeBps = protocolFeeBps;
        uint16 newFeeBps = pendingProtocolFeeBps;
        protocolFeeBps = newFeeBps;
        pendingProtocolFeeBps = 0;
        pendingProtocolFeeEffectiveAt = 0;
        emit ProtocolFeeChanged(oldFeeBps, newFeeBps);
    }

    /// @notice Cancel an unapplied fee update before it becomes effective.
    function cancelProtocolFeeChange() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint64 effectiveAt = pendingProtocolFeeEffectiveAt;
        if (effectiveAt == 0) revert NoPendingFeeChange();
        uint16 pendingFeeBps = pendingProtocolFeeBps;
        pendingProtocolFeeBps = 0;
        pendingProtocolFeeEffectiveAt = 0;
        emit ProtocolFeeChangeCancelled(pendingFeeBps, effectiveAt);
    }

    /// @notice Create and fund a job against the current verified Escrow listing.
    /// @dev The current protocol fee is copied into the job before funding.
    function createJob(
        bytes32 clientReference,
        uint256 listingId,
        bytes32 termsHash,
        uint256 amount,
        uint64 reviewHours
    ) external whenNotPaused nonReentrant returns (uint256 jobId) {
        if (clientReference == bytes32(0)) revert InvalidReference();
        if (termsHash == bytes32(0)) revert ZeroHash();
        if (amount == 0) revert ZeroAmount();
        if (reviewHours == 0) reviewHours = defaultReviewHours;
        _validateReviewHours(reviewHours);
        if (jobByReference[msg.sender][clientReference] != 0) revert JobReferenceAlreadyUsed();

        IAgonServiceRegistry.Listing memory listing = serviceRegistry.getListing(listingId);
        if (!serviceRegistry.escrowEligible(listingId)) revert ListingNotEscrowEligible();
        if (listing.providerSnapshot == address(0) || listing.manifestHash == bytes32(0) || listing.version == 0) {
            revert InvalidListingSnapshot();
        }

        uint16 feeBps = protocolFeeBps;
        uint256 fee = (amount * feeBps) / BPS;
        uint256 total = amount + fee;
        jobId = _nextJobId++;
        uint64 createdAt = uint64(block.timestamp);
        uint64 acceptanceDeadline = createdAt + uint64(uint256(reviewHours) * 1 hours);
        _jobs[jobId] = Job({
            jobId: jobId,
            buyer: msg.sender,
            provider: listing.providerSnapshot,
            listingId: listingId,
            agentId: listing.agentId,
            listingVersion: listing.version,
            manifestHash: listing.manifestHash,
            termsHash: termsHash,
            deliverableHash: bytes32(0),
            amount: amount,
            fee: fee,
            feeBps: feeBps,
            reviewHours: reviewHours,
            acceptanceDeadline: acceptanceDeadline,
            reviewDeadline: 0,
            createdAt: createdAt,
            submittedAt: 0,
            status: Status.Created,
            settlement: Settlement.None
        });
        jobByReference[msg.sender][clientReference] = jobId;
        _pausedMarkAtCreate[jobId] = _pausedSecondsTotal;
        usdc.safeTransferFrom(msg.sender, address(this), total);
        _emitJobCreated(jobId, clientReference);
    }

    /// @notice The provider takes a Created job. Only inside the acceptance window, and not while paused.
    /// @param jobId The job.
    function acceptJob(uint256 jobId) external whenNotPaused {
        Job storage job = _job(jobId);
        if (msg.sender != job.provider) revert NotProvider();
        if (job.status != Status.Created) revert InvalidStatus();
        if (block.timestamp > effectiveAcceptanceDeadline(jobId)) revert AcceptanceWindowClosed();
        job.status = Status.Accepted;
        emit JobAccepted(jobId, msg.sender);
    }

    /// @notice The provider delivers an Accepted job, inside the same acceptance window. Starts the buyer's
    ///         review window of `reviewHours`.
    /// @param jobId The job.
    /// @param deliverableHash Hash of the delivery, not zero.
    function submitJob(uint256 jobId, bytes32 deliverableHash) external whenNotPaused {
        Job storage job = _job(jobId);
        if (msg.sender != job.provider) revert NotProvider();
        if (job.status != Status.Accepted) revert InvalidStatus();
        if (block.timestamp > effectiveAcceptanceDeadline(jobId)) revert AcceptanceWindowClosed();
        if (deliverableHash == bytes32(0)) revert ZeroHash();
        job.deliverableHash = deliverableHash;
        job.submittedAt = uint64(block.timestamp);
        job.reviewDeadline = uint64(block.timestamp) + uint64(uint256(job.reviewHours) * 1 hours);
        job.status = Status.Submitted;
        emit JobSubmitted(jobId, deliverableHash, job.reviewDeadline);
    }

    /// @notice The buyer accepts the delivery inside the review window: amount to the provider, fee to the treasury.
    /// @param jobId A Submitted job.
    function acceptSubmission(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (msg.sender != job.buyer) revert NotBuyer();
        if (job.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp > job.reviewDeadline) revert ReviewWindowClosed();
        _payProvider(job);
    }

    /// @notice Anyone pays the provider once the review window has passed without a rejection.
    /// @param jobId A Submitted job.
    function autoAccept(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (job.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp <= job.reviewDeadline) revert ReviewWindowOpen();
        _payProvider(job);
    }

    /// @notice The buyer rejects the delivery inside the review window. Starts the 7-day rejection window,
    ///         in which either party may open a dispute or the provider may accept the rejection.
    /// @param jobId A Submitted job.
    /// @param reasonHash Hash of the buyer's reason, not zero.
    function rejectSubmission(uint256 jobId, bytes32 reasonHash) external {
        Job storage job = _job(jobId);
        if (msg.sender != job.buyer) revert NotBuyer();
        if (job.status != Status.Submitted) revert InvalidStatus();
        if (block.timestamp > job.reviewDeadline) revert ReviewWindowClosed();
        if (reasonHash == bytes32(0)) revert ZeroHash();
        job.status = Status.Rejected;
        rejectedAt[jobId] = uint64(block.timestamp);
        emit JobRejected(jobId, reasonHash);
    }

    /// @notice Open a dispute on a rejected job. Must happen inside REJECTION_WINDOW.
    function openDispute(uint256 jobId, bytes32 reasonHash) external {
        Job storage job = _job(jobId);
        if (msg.sender != job.provider && msg.sender != job.buyer) revert NotParty();
        if (job.status != Status.Rejected) revert InvalidStatus();
        if (reasonHash == bytes32(0)) revert ZeroHash();
        if (block.timestamp > uint256(rejectedAt[jobId]) + REJECTION_WINDOW) revert RejectionWindowClosed();
        job.status = Status.Disputed;
        disputedAt[jobId] = uint64(block.timestamp);
        emit JobDisputed(jobId, msg.sender, reasonHash);
    }

    /// @notice Buyer exit for a rejection that nobody disputed.
    /// @dev Refunds amount plus fee. The fee is returned because the job never
    ///      completed, so the protocol earned nothing. Same payout as failJob.
    function claimRefundAfterRejection(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (job.status != Status.Rejected) revert InvalidStatus();
        if (block.timestamp <= uint256(rejectedAt[jobId]) + REJECTION_WINDOW) revert RejectionWindowOpen();
        _refundBuyer(job);
        emit RejectionRefundClaimed(jobId, job.buyer, job.amount + job.fee);
    }

    /// @notice Exit for a dispute the resolver did not settle in RESOLVER_WINDOW.
    /// @dev Either party may call. The buyer gets amount plus fee back, since
    ///      no ruling ever found the work acceptable.
    function exitStaleDispute(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (msg.sender != job.buyer && msg.sender != job.provider) revert NotParty();
        if (job.status != Status.Disputed) revert InvalidStatus();
        if (block.timestamp <= uint256(disputedAt[jobId]) + RESOLVER_WINDOW) revert ResolverWindowOpen();
        _refundBuyer(job);
        emit StaleDisputeExited(jobId, msg.sender, job.amount + job.fee);
    }

    /// @notice Settle an open dispute. Only valid inside RESOLVER_WINDOW.
    function resolveDispute(uint256 jobId, bool payProvider) external nonReentrant {
        if (msg.sender != disputeResolver) revert NotDisputeResolver();
        Job storage job = _job(jobId);
        if (job.status != Status.Disputed) revert InvalidStatus();
        if (block.timestamp > uint256(disputedAt[jobId]) + RESOLVER_WINDOW) revert ResolverWindowClosed();
        if (payProvider) {
            _payProvider(job);
        } else {
            _refundBuyer(job);
        }
    }

    /// @notice Refund the buyer, amount and fee, for a job not delivered inside its acceptance window.
    /// @dev Anyone may call (Arc rejects transactions from a blocklisted buyer). Pays only the buyer.
    /// @param jobId A Created or Accepted job.
    function failJob(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (job.status != Status.Created && job.status != Status.Accepted) revert InvalidStatus();
        if (block.timestamp <= effectiveAcceptanceDeadline(jobId)) revert AcceptanceWindowOpen();
        _refundBuyer(job);
    }

    /// @notice The provider agrees with a rejection and returns the buyer's money at once,
    ///         instead of waiting out the rejection window.
    /// @param jobId A Rejected job.
    function acceptRejection(uint256 jobId) external nonReentrant {
        Job storage job = _job(jobId);
        if (msg.sender != job.provider) revert NotProvider();
        if (job.status != Status.Rejected) revert InvalidStatus();
        _refundBuyer(job);
        emit RejectionAccepted(jobId, msg.sender);
    }

    /// @notice Withdraw USDC credited to the caller when a payout to it could not be sent.
    /// @dev Pays only the caller, never another address, so a blocklisted account cannot move
    ///      its funds elsewhere. Reverts while the caller still cannot receive USDC.
    function withdrawCredit() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NoCredit();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit CreditWithdrawn(msg.sender, amount);
    }

    /// @notice Pausing stops the acceptance clock of every open job.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        _pausedSince = uint64(block.timestamp);
    }

    /// @notice Resume the provider side. The time spent paused is added to every open acceptance window.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        _pausedSecondsTotal += block.timestamp - _pausedSince;
        _pausedSince = 0;
    }

    /// @notice Last moment the provider can accept and submit, moved out by paused time.
    /// @dev One window covers both accepting and delivering: it is reviewHours long from
    ///      creation, the same length as the buyer's review window after submission.
    function effectiveAcceptanceDeadline(uint256 jobId) public view returns (uint256) {
        Job storage job = _job(jobId);
        uint256 pausedNow = _pausedSecondsTotal;
        if (paused()) pausedNow += block.timestamp - _pausedSince;
        return uint256(job.acceptanceDeadline) + pausedNow - _pausedMarkAtCreate[jobId];
    }

    /// @notice Change where fees are paid. Applies to every later settlement, including open jobs.
    /// @param newTreasury The new fee address, not zero.
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Read a job. Reverts with JobMissing when it does not exist.
    /// @param jobId The job.
    /// @return The job.
    function getJob(uint256 jobId) external view returns (Job memory) {
        return _job(jobId);
    }

    /// @notice USDC still held for a job: amount plus fee until it settles, then 0.
    /// @param jobId The job.
    /// @return The held amount.
    function escrowedAmount(uint256 jobId) external view returns (uint256) {
        Job memory job = _job(jobId);
        if (job.settlement != Settlement.None) return 0;
        return job.amount + job.fee;
    }

    /// @dev Settles a job as ProviderPaid: amount to the provider, fee to the current treasury.
    function _payProvider(Job storage job) private {
        job.status = Status.Complete;
        job.settlement = Settlement.ProviderPaid;
        _send(job.provider, job.amount);
        if (job.fee != 0) _send(treasury, job.fee);
        emit JobSettled(job.jobId, Settlement.ProviderPaid, job.provider, job.amount, job.fee);
    }

    /// @dev Emits JobCreated from storage, kept apart from createJob to avoid stack-too-deep.
    function _emitJobCreated(uint256 jobId, bytes32 clientReference) private {
        Job storage job = _jobs[jobId];
        emit JobCreated(
            jobId,
            clientReference,
            job.buyer,
            job.provider,
            job.listingId,
            job.agentId,
            job.listingVersion,
            job.manifestHash,
            job.termsHash,
            job.amount,
            job.fee,
            job.feeBps,
            job.reviewHours,
            job.acceptanceDeadline
        );
    }

    /// @dev Settles a job as BuyerRefunded: amount plus fee to the buyer.
    function _refundBuyer(Job storage job) private {
        job.status = Status.Failed;
        job.settlement = Settlement.BuyerRefunded;
        uint256 total = job.amount + job.fee;
        _send(job.buyer, total);
        emit JobFailed(job.jobId, msg.sender, Settlement.BuyerRefunded);
        emit JobSettled(job.jobId, Settlement.BuyerRefunded, job.buyer, total, 0);
    }

    /// @dev Sends USDC, or credits it when the transfer fails (Arc reverts transfers to a
    ///      blocklisted address), so one party can never freeze a settlement.
    function _send(address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(usdc).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (data.length == 0 ? address(usdc).code.length != 0 : data.length >= 32 && abi.decode(data, (bool)))) {
            return;
        }
        credits[to] += amount;
        totalCredits += amount;
        emit PayoutCredited(to, amount);
    }

    /// @dev The job in storage, or JobMissing.
    function _job(uint256 jobId) private view returns (Job storage job) {
        job = _jobs[jobId];
        if (job.jobId == 0) revert JobMissing();
    }

    /// @dev Review hours must be 1 to 720.
    function _validateReviewHours(uint64 reviewHours) private pure {
        if (reviewHours < MIN_REVIEW_HOURS || reviewHours > MAX_REVIEW_HOURS) revert InvalidReviewHours();
    }

    /// @dev The protocol fee must be at most MAX_PROTOCOL_FEE_BPS (10%).
    function _validateProtocolFee(uint16 feeBps) private pure {
        if (feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeAboveMaximum();
    }
}
