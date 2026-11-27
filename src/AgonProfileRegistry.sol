// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC8004Identity } from "./interfaces/IERC8004Identity.sol";

/// @title AgonProfileRegistry
/// @notice An agent's Agon profile, bound to its ERC-8004 identity. The identity's current owner
///         controls the profile; the admin can suspend and reinstate it.
/// @dev Ownership is read live from the identity registry on every call; `ownerSnapshot` is a record only.
contract AgonProfileRegistry is AccessControl {
    enum Status {
        Active,
        Suspended,
        Archived
    }

    struct Profile {
        uint256 agentId;
        string metadataURI;
        Status status;
        address ownerSnapshot;
        uint64 createdAt;
        uint64 updatedAt;
        bytes32 suspensionReason;
    }
    mapping(uint256 => Profile) private profiles;
    IERC8004Identity public immutable identityRegistry;
    error NotIdentityOwner();
    error IdentityDoesNotExist();
    error ZeroAgentId();
    error ProfileAlreadyBound();
    error InvalidMetadataURI();
    error MissingIdentity();
    error ProfileNotSuspended();
    error ProfileNotActive();
    error ZeroAddress();
    event ProfileBound(uint256 indexed agentId, address indexed owner, string metadataURI);
    event ProfileMetadataUpdated(uint256 indexed agentId, address indexed owner, string metadataURI);
    event ProfileStatusChanged(uint256 indexed agentId, address indexed actor, Status status, bytes32 reason);
    event OwnershipSynced(uint256 indexed agentId, address indexed previousOwner, address indexed newOwner);

    /// @param admin Receives DEFAULT_ADMIN_ROLE (suspend and reinstate).
    /// @param identity The ERC-8004 identity registry read for ownership.
    constructor(address admin, address identity) {
        if (admin == address(0) || identity == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        identityRegistry = IERC8004Identity(identity);
    }

    /// @notice The identity's current owner, or address 0 when it does not exist or cannot be read.
    /// @param id The ERC-8004 agent id.
    /// @return The owner, or address 0.
    function currentOwner(uint256 id) public view returns (address) {
        if (id == 0) return address(0);
        try identityRegistry.ownerOf(id) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }
    modifier onlyOwner(uint256 id) {
        address o = currentOwner(id);
        if (o == address(0)) revert IdentityDoesNotExist();
        if (o != msg.sender) revert NotIdentityOwner();
        _;
    }

    /// @notice Create the profile for an identity the caller owns. Once per identity.
    /// @param id The ERC-8004 agent id.
    /// @param uri Profile metadata URI, 1 to 2,048 bytes.
    function bindProfile(uint256 id, string calldata uri) external {
        if (id == 0) revert ZeroAgentId();
        address o = currentOwner(id);
        if (o == address(0)) revert IdentityDoesNotExist();
        if (o != msg.sender) revert NotIdentityOwner();
        if (bytes(uri).length == 0 || bytes(uri).length > 2048) revert InvalidMetadataURI();
        if (profiles[id].agentId != 0) revert ProfileAlreadyBound();
        profiles[id] =
            Profile(id, uri, Status.Active, msg.sender, uint64(block.timestamp), uint64(block.timestamp), bytes32(0));
        emit ProfileBound(id, msg.sender, uri);
    }

    /// @notice Replace the profile's metadata URI and record the caller as owner.
    /// @param id The ERC-8004 agent id.
    /// @param uri New metadata URI, 1 to 2,048 bytes.
    function updateProfile(uint256 id, string calldata uri) external onlyOwner(id) {
        if (profiles[id].agentId == 0) revert MissingIdentity();
        if (bytes(uri).length == 0 || bytes(uri).length > 2048) revert InvalidMetadataURI();
        profiles[id].metadataURI = uri;
        profiles[id].ownerSnapshot = msg.sender;
        profiles[id].updatedAt = uint64(block.timestamp);
        emit ProfileMetadataUpdated(id, msg.sender, uri);
    }

    /// @notice Record the identity's current owner in the profile after a transfer.
    /// @param id The ERC-8004 agent id.
    function syncOwnership(uint256 id) external onlyOwner(id) {
        if (profiles[id].agentId == 0) revert MissingIdentity();
        address old = profiles[id].ownerSnapshot;
        address n = currentOwner(id);
        profiles[id].ownerSnapshot = n;
        profiles[id].updatedAt = uint64(block.timestamp);
        emit OwnershipSynced(id, old, n);
    }

    /// @notice Suspend an Active profile. A suspended profile cannot publish, version or relist listings.
    /// @dev Only from Active, so an Archived profile can never be brought back through suspend and reinstate.
    /// @param id The ERC-8004 agent id.
    /// @param reason Hash of the reason, kept on the profile.
    function suspendProfile(uint256 id, bytes32 reason) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (profiles[id].agentId == 0) revert MissingIdentity();
        if (profiles[id].status != Status.Active) revert ProfileNotActive();
        profiles[id].status = Status.Suspended;
        profiles[id].suspensionReason = reason;
        profiles[id].updatedAt = uint64(block.timestamp);
        emit ProfileStatusChanged(id, msg.sender, Status.Suspended, reason);
    }

    /// @notice Lift a suspension. Only a Suspended profile can return to Active; Archived stays archived.
    function reinstateProfile(uint256 id) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (profiles[id].agentId == 0) revert MissingIdentity();
        if (profiles[id].status != Status.Suspended) revert ProfileNotSuspended();
        profiles[id].status = Status.Active;
        profiles[id].suspensionReason = bytes32(0);
        profiles[id].updatedAt = uint64(block.timestamp);
        emit ProfileStatusChanged(id, msg.sender, Status.Active, bytes32(0));
    }

    /// @notice Archive the caller's profile. Archiving is meant to be final.
    /// @param id The ERC-8004 agent id.
    function archiveProfile(uint256 id) external onlyOwner(id) {
        if (profiles[id].agentId == 0) revert MissingIdentity();
        profiles[id].status = Status.Archived;
        profiles[id].updatedAt = uint64(block.timestamp);
        emit ProfileStatusChanged(id, msg.sender, Status.Archived, bytes32(0));
    }

    /// @notice Read a profile. Reverts with MissingIdentity when none is bound.
    /// @param id The ERC-8004 agent id.
    /// @return The profile.
    function getProfile(uint256 id) external view returns (Profile memory) {
        if (profiles[id].agentId == 0) revert MissingIdentity();
        return profiles[id];
    }
}
