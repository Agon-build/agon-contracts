// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IAgonServiceRegistry } from "../../src/interfaces/IAgonServiceRegistry.sol";

/// @notice A registry that returns whatever listing the test sets, so the escrow's own checks on a
///         listing's snapshot can be reached even though the real registry never returns such data.
contract FakeServiceRegistry is IAgonServiceRegistry {
    Listing internal _listing;
    bool public eligible = true;

    function set(address provider, bytes32 manifestHash, uint256 version) external {
        _listing.listingId = 1;
        _listing.agentId = 42;
        _listing.providerSnapshot = provider;
        _listing.manifestHash = manifestHash;
        _listing.version = version;
        _listing.paymentRail = PaymentRail.Escrow;
        _listing.verification = Verification.Verified;
    }

    function getListing(uint256) external view returns (Listing memory) {
        return _listing;
    }

    function escrowEligible(uint256) external view returns (bool) {
        return eligible;
    }
}
