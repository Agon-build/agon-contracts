// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAgonServiceRegistry
/// @notice The part of the Agon service registry that other Agon contracts read.
/// @dev Matches AgonServiceRegistryV2 field for field and value for value.
///      `test/RegistryInterface.t.sol` pins the struct layout and every enum order,
///      so a change to the registry that breaks a reader fails the tests.
interface IAgonServiceRegistry {
    /// @notice Whether a listing can be hired.
    enum ListingStatus {
        Listed,
        Suspended,
        Delisted
    }

    /// @notice Agon's verification of a listing's current version.
    enum Verification {
        Unverified,
        Pending,
        Verified,
        Expired,
        Suspended,
        Revoked
    }

    /// @notice How a listing is paid: per call over x402, or as an escrowed job.
    enum PaymentRail {
        X402,
        Escrow
    }

    /// @notice A listing as the registry stores it.
    /// @param listingId The listing's id, never 0 for a listing that exists.
    /// @param agentId The ERC-8004 agent the listing belongs to.
    /// @param serviceKey The agent's key for this service, unique per agent.
    /// @param manifestHash Hash of the current version's service file.
    /// @param manifestURI Where the current service file is published.
    /// @param category The listing's category id.
    /// @param paymentRail How the listing is paid.
    /// @param version The current version, starting at 1.
    /// @param providerSnapshot The address that published the current version; it receives escrow payouts.
    /// @param status Whether the listing can be hired.
    /// @param verification Agon's verification of the current version.
    /// @param createdAt When the listing was first published.
    /// @param updatedAt When the listing last changed.
    struct Listing {
        uint256 listingId;
        uint256 agentId;
        bytes32 serviceKey;
        bytes32 manifestHash;
        string manifestURI;
        uint256 category;
        PaymentRail paymentRail;
        uint256 version;
        address providerSnapshot;
        ListingStatus status;
        Verification verification;
        uint64 createdAt;
        uint64 updatedAt;
    }

    /// @notice Reads a listing. Reverts when it does not exist.
    /// @param id The listing id.
    /// @return The listing.
    function getListing(uint256 id) external view returns (Listing memory);

    /// @notice Whether a listing may take escrowed jobs: Listed, escrow rail, Verified and a usable profile.
    /// @param id The listing id.
    /// @return True when an escrowed job may be created against it.
    function escrowEligible(uint256 id) external view returns (bool);
}
