// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title AgonPrizeVault
/// @notice Holds Arena and syndicate prize pools and settles immutable
///         contribution-weighted Merkle claims through pull payments.
contract AgonPrizeVault is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant POOL_OPERATOR_ROLE = keccak256("POOL_OPERATOR_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1000;
    /// @notice Time after funding in which the operator must publish a payout root.
    /// @dev After it passes with no root, anyone can return the principal to the sponsor.
    ///      Paused time does not count toward it.
    uint64 public constant ROOT_PUBLISH_WINDOW = 30 days;

    enum PoolKind {
        Arena,
        Syndicate
    }

    enum State {
        Funded,
        RootPublished,
        Closed
    }

    struct Pool {
        bytes32 poolKey;
        PoolKind kind;
        uint256 sourceId;
        address sponsor;
        uint256 principal;
        uint256 fee;
        bytes32 payoutRoot;
        uint256 payoutTotal;
        uint256 claimedTotal;
        uint64 claimDeadline;
        State state;
    }

    IERC20 public immutable usdc;
    address public treasury;
    mapping(bytes32 => Pool) private _pools;
    mapping(bytes32 => mapping(uint256 => uint256)) private _claimedBitmap;
    /// @notice When each pool was funded. Kept outside Pool so getPool stays ABI stable.
    mapping(bytes32 => uint64) public fundedAt;
    /// @dev Paused seconds counted at funding and at root publication. A pool's
    ///      deadlines move forward by the paused time that accrued after these marks.
    mapping(bytes32 => uint256) private _pausedMarkAtFunding;
    mapping(bytes32 => uint256) private _pausedMarkAtPublish;
    uint256 private _pausedSecondsTotal;
    uint64 private _pausedSince;
    /// @notice USDC owed to an address whose payout could not be sent (for example a blocklisted
    ///         address on Arc). The claim or refund still completes; the owner withdraws it with withdrawCredit.
    mapping(address => uint256) public credits;
    /// @notice Sum of all credits. Part of what the vault must hold.
    uint256 public totalCredits;

    event PoolFunded(
        bytes32 indexed poolKey,
        PoolKind indexed kind,
        uint256 indexed sourceId,
        address sponsor,
        uint256 principal,
        uint256 fee
    );
    event PayoutRootPublished(
        bytes32 indexed poolKey, bytes32 indexed payoutRoot, uint256 payoutTotal, uint64 claimDeadline
    );
    event PrizeClaimed(bytes32 indexed poolKey, uint256 indexed index, address indexed beneficiary, uint256 amount);
    event PoolRefunded(bytes32 indexed poolKey, address indexed sponsor, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event UnpublishedPoolRefunded(bytes32 indexed poolKey, address indexed sponsor, uint256 amount);
    event PayoutCredited(address indexed account, uint256 amount);
    event CreditWithdrawn(address indexed account, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroHash();
    error InvalidFee();
    error PoolAlreadyExists();
    error PoolMissing();
    error InvalidState();
    error InvalidRoot();
    error PayoutExceedsPrincipal();
    error ClaimWindowClosed();
    error AlreadyClaimed();
    error InvalidProof();
    error RefundWindowOpen();
    error SponsorMustBeCaller();
    error RootPublishWindowOpen();
    error RootPublishWindowClosed();
    error NoCredit();

    constructor(address admin, address usdcAddress, address treasuryAddress) {
        if (admin == address(0) || usdcAddress == address(0) || treasuryAddress == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POOL_OPERATOR_ROLE, admin);
        usdc = IERC20(usdcAddress);
        treasury = treasuryAddress;
    }

    /// @notice Fund a pool from the caller's own balance.
    /// @dev The sponsor must be msg.sender. A standing approval to the vault can
    ///      never be spent by anyone else, so one approval cannot be charged twice.
    ///      The caller still needs POOL_OPERATOR_ROLE.
    function createPool(
        bytes32 poolKey,
        PoolKind kind,
        uint256 sourceId,
        address sponsor,
        uint256 principal,
        uint16 feeBps
    ) external onlyRole(POOL_OPERATOR_ROLE) whenNotPaused {
        if (poolKey == bytes32(0)) revert ZeroHash();
        if (sponsor == address(0)) revert ZeroAddress();
        if (sponsor != msg.sender) revert SponsorMustBeCaller();
        if (principal == 0) revert ZeroAmount();
        if (feeBps > MAX_FEE_BPS) revert InvalidFee();
        if (_pools[poolKey].poolKey != bytes32(0)) revert PoolAlreadyExists();
        uint256 fee = (principal * uint256(feeBps)) / BPS;
        _pools[poolKey] = Pool({
            poolKey: poolKey,
            kind: kind,
            sourceId: sourceId,
            sponsor: sponsor,
            principal: principal,
            fee: fee,
            payoutRoot: bytes32(0),
            payoutTotal: 0,
            claimedTotal: 0,
            claimDeadline: 0,
            state: State.Funded
        });
        fundedAt[poolKey] = uint64(block.timestamp);
        _pausedMarkAtFunding[poolKey] = _pausedSecondsNow();
        usdc.safeTransferFrom(sponsor, address(this), principal + fee);
        if (fee != 0) usdc.safeTransfer(treasury, fee);
        emit PoolFunded(poolKey, kind, sourceId, sponsor, principal, fee);
    }

    /// @notice Publish the Merkle root of a Funded pool's payouts, within 30 days of funding plus paused time.
    /// @param poolKey The pool.
    /// @param payoutRoot Root over leaves keccak256(keccak256(abi.encode(index, beneficiary, amount))).
    /// @param payoutTotal Sum of the leaves, above 0 and at most the principal.
    /// @param claimDeadline Last moment to claim, in the future.
    function publishPayoutRoot(bytes32 poolKey, bytes32 payoutRoot, uint256 payoutTotal, uint64 claimDeadline)
        external
        onlyRole(POOL_OPERATOR_ROLE)
        whenNotPaused
    {
        Pool storage pool = _pool(poolKey);
        if (pool.state != State.Funded) revert InvalidState();
        if (block.timestamp > rootPublishDeadline(poolKey)) revert RootPublishWindowClosed();
        if (payoutRoot == bytes32(0) || payoutTotal == 0) revert InvalidRoot();
        if (payoutTotal > pool.principal) revert PayoutExceedsPrincipal();
        if (claimDeadline <= block.timestamp) revert ClaimWindowClosed();
        pool.payoutRoot = payoutRoot;
        pool.payoutTotal = payoutTotal;
        pool.claimDeadline = claimDeadline;
        pool.state = State.RootPublished;
        _pausedMarkAtPublish[poolKey] = _pausedSecondsNow();
        emit PayoutRootPublished(poolKey, payoutRoot, payoutTotal, claimDeadline);
    }

    /// @notice Pay one leaf of a published root to its beneficiary. Anyone may submit it; each index once.
    /// @param poolKey The pool.
    /// @param index The leaf index.
    /// @param beneficiary The address in the leaf, which is paid.
    /// @param amount The amount in the leaf.
    /// @param proof Merkle proof for the leaf.
    function claim(bytes32 poolKey, uint256 index, address beneficiary, uint256 amount, bytes32[] calldata proof)
        external
        whenNotPaused
        nonReentrant
    {
        Pool storage pool = _pool(poolKey);
        if (pool.state != State.RootPublished) revert InvalidState();
        if (block.timestamp > effectiveClaimDeadline(poolKey)) revert ClaimWindowClosed();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_isClaimed(poolKey, index)) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, beneficiary, amount))));
        if (!MerkleProof.verify(proof, pool.payoutRoot, leaf)) revert InvalidProof();
        if (pool.claimedTotal + amount > pool.payoutTotal) revert PayoutExceedsPrincipal();
        _setClaimed(poolKey, index);
        pool.claimedTotal += amount;
        _send(beneficiary, amount);
        emit PrizeClaimed(poolKey, index, beneficiary, amount);
    }

    /// @notice Return unclaimed principal to the sponsor once every prize is claimed or the claim window has closed.
    /// @dev Anyone may call. Funds only go to the sponsor.
    function refundRemaining(bytes32 poolKey) external nonReentrant {
        Pool storage pool = _pool(poolKey);
        if (pool.state != State.RootPublished) revert InvalidState();
        if (pool.claimedTotal != pool.payoutTotal && block.timestamp <= effectiveClaimDeadline(poolKey)) {
            revert RefundWindowOpen();
        }
        uint256 remaining = pool.principal - pool.claimedTotal;
        pool.state = State.Closed;
        if (remaining != 0) _send(pool.sponsor, remaining);
        emit PoolRefunded(poolKey, pool.sponsor, remaining);
    }

    /// @notice Return the principal of a pool whose root was never published.
    /// @dev Anyone may call. Funds only go to the sponsor. The fee already went
    ///      to the treasury at funding and is not part of this refund.
    function refundUnpublished(bytes32 poolKey) external nonReentrant {
        Pool storage pool = _pool(poolKey);
        if (pool.state != State.Funded) revert InvalidState();
        if (block.timestamp <= rootPublishDeadline(poolKey)) revert RootPublishWindowOpen();
        uint256 amount = pool.principal;
        pool.state = State.Closed;
        _send(pool.sponsor, amount);
        emit UnpublishedPoolRefunded(poolKey, pool.sponsor, amount);
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

    /// @notice Pausing stops the clock on root publication and claim windows.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
        _pausedSince = uint64(block.timestamp);
    }

    /// @notice Resume the vault. The time spent paused extends root publish and claim deadlines.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
        _pausedSecondsTotal += block.timestamp - _pausedSince;
        _pausedSince = 0;
    }

    /// @notice Last moment a payout root can be published, moved out by paused time.
    function rootPublishDeadline(bytes32 poolKey) public view returns (uint256) {
        _pool(poolKey);
        return uint256(fundedAt[poolKey]) + ROOT_PUBLISH_WINDOW + _pausedSecondsNow()
            - _pausedMarkAtFunding[poolKey];
    }

    /// @notice Claim deadline moved out by any pause after the root was published.
    /// @dev A pause that starts after the deadline also moves it. That only gives
    ///      claimants more time and delays the sponsor refund by the same amount.
    function effectiveClaimDeadline(bytes32 poolKey) public view returns (uint256) {
        Pool storage pool = _pool(poolKey);
        if (pool.state == State.Funded) return 0;
        return uint256(pool.claimDeadline) + _pausedSecondsNow() - _pausedMarkAtPublish[poolKey];
    }

    /// @notice Change where pool fees are paid. Applies to pools funded after the change.
    /// @param newTreasury The new fee address, not zero.
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Read a pool. Reverts with PoolMissing when it does not exist.
    /// @param poolKey The pool.
    /// @return The pool.
    function getPool(bytes32 poolKey) external view returns (Pool memory) {
        return _pool(poolKey);
    }

    /// @notice Whether a leaf index of a pool has been claimed.
    /// @param poolKey The pool.
    /// @param index The leaf index.
    /// @return True once claimed.
    function isClaimed(bytes32 poolKey, uint256 index) external view returns (bool) {
        return _isClaimed(poolKey, index);
    }

    /// @dev Sends USDC, or credits it when the transfer fails (Arc reverts transfers to a
    ///      blocklisted address), so one party can never freeze a pool.
    function _send(address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(usdc).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (data.length == 0 ? address(usdc).code.length != 0 : data.length >= 32 && abi.decode(data, (bool)))) {
            return;
        }
        credits[to] += amount;
        totalCredits += amount;
        emit PayoutCredited(to, amount);
    }

    /// @dev The pool in storage, or PoolMissing.
    function _pool(bytes32 poolKey) private view returns (Pool storage pool) {
        pool = _pools[poolKey];
        if (pool.poolKey == bytes32(0)) revert PoolMissing();
    }

    /// @dev Total paused seconds so far, including a pause still running.
    function _pausedSecondsNow() private view returns (uint256) {
        if (paused()) return _pausedSecondsTotal + (block.timestamp - _pausedSince);
        return _pausedSecondsTotal;
    }

    /// @dev Reads the claimed bit of a leaf index (256 indexes per word).
    function _isClaimed(bytes32 poolKey, uint256 index) private view returns (bool) {
        return (_claimedBitmap[poolKey][index / 256] & (uint256(1) << (index % 256))) != 0;
    }

    /// @dev Sets the claimed bit of a leaf index.
    function _setClaimed(bytes32 poolKey, uint256 index) private {
        _claimedBitmap[poolKey][index / 256] |= uint256(1) << (index % 256);
    }
}
