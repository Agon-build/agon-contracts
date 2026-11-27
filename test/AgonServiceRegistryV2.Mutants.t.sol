// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";

contract MutantsServiceIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @dev A profile registry whose read fails with an error other than MissingIdentity.
contract BrokenProfiles {
    error SomethingElse();

    function getProfile(uint256) external pure returns (uint256) {
        revert SomethingElse();
    }
}

/// @notice Tests added after mutation testing (2026-11-26) showed these behaviours were not
///         checked: the constructor's admin grant, every field and time a new version writes,
///         the times status and verification changes write, the publisher recorded as the
///         caller rather than the transaction origin, and a failed profile read that is not
///         MissingIdentity. Times start past 2^32 so a 32-bit timestamp cast would show.
contract AgonServiceRegistryV2MutantsTest is Test {
    MutantsServiceIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    address internal admin = makeAddr("admin");
    address internal provider = makeAddr("provider");
    address internal origin = makeAddr("origin");
    bytes32 internal constant KEY = keccak256("secure-review");
    bytes32 internal constant MANIFEST_1 = keccak256("manifest-v1");
    bytes32 internal constant MANIFEST_2 = keccak256("manifest-v2");
    uint64 internal constant T0 = uint64(1) << 32;

    function setUp() public {
        identity = new MutantsServiceIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        identity.mint(provider, 42);
        vm.prank(provider);
        profiles.bindProfile(42, "ipfs://profile");
    }

    function _publish() internal returns (uint256 id) {
        vm.prank(provider, origin);
        id = services.publish(42, KEY, MANIFEST_1, "ipfs://v1", 1, AgonServiceRegistryV2.PaymentRail.X402);
    }

    function test_constructor_grantsTheAdminRole() public view {
        assertTrue(services.hasRole(services.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_publish_recordsTimesAndTheCaller() public {
        vm.warp(T0 + 1_000);
        vm.expectEmit(true, true, true, true, address(services));
        emit AgonServiceRegistryV2.ListingPublished(
            1,
            42,
            KEY,
            MANIFEST_1,
            "ipfs://v1",
            1,
            AgonServiceRegistryV2.PaymentRail.X402,
            1,
            provider,
            AgonServiceRegistryV2.ListingStatus.Listed,
            AgonServiceRegistryV2.Verification.Unverified
        );
        uint256 id = _publish();
        AgonServiceRegistryV2.Listing memory l = services.getListing(id);
        assertEq(l.createdAt, T0 + 1_000);
        assertEq(l.updatedAt, T0 + 1_000);
        assertEq(l.providerSnapshot, provider);
        AgonServiceRegistryV2.Version memory v = services.getVersion(id, 1);
        assertEq(v.createdAt, T0 + 1_000);
        assertEq(v.providerSnapshot, provider);
    }

    function test_publishVersion_writesEveryField() public {
        vm.warp(T0 + 1_000);
        uint256 id = _publish();
        vm.warp(T0 + 2_000);
        vm.expectEmit(true, true, true, true, address(services));
        emit AgonServiceRegistryV2.ListingVersionPublished(
            id, 2, MANIFEST_2, "ipfs://v2", AgonServiceRegistryV2.PaymentRail.Escrow, provider
        );
        vm.prank(provider, origin);
        services.publishVersion(id, MANIFEST_2, "ipfs://v2", AgonServiceRegistryV2.PaymentRail.Escrow);

        AgonServiceRegistryV2.Listing memory l = services.getListing(id);
        assertEq(l.version, 2);
        assertEq(l.manifestHash, MANIFEST_2);
        assertEq(l.manifestURI, "ipfs://v2");
        assertEq(uint8(l.paymentRail), uint8(AgonServiceRegistryV2.PaymentRail.Escrow));
        assertEq(l.updatedAt, T0 + 2_000);
        assertEq(l.createdAt, T0 + 1_000);

        AgonServiceRegistryV2.Version memory v = services.getVersion(id, 2);
        assertEq(v.createdAt, T0 + 2_000);
        assertEq(v.providerSnapshot, provider);
        assertEq(v.manifestURI, "ipfs://v2");
    }

    function test_setStatus_stampsTimeAndEmits() public {
        vm.warp(T0 + 1_000);
        uint256 id = _publish();
        vm.warp(T0 + 3_000);
        vm.expectEmit(true, true, false, true, address(services));
        emit AgonServiceRegistryV2.ListingStatusChanged(id, provider, AgonServiceRegistryV2.ListingStatus.Delisted);
        vm.prank(provider);
        services.setStatus(id, AgonServiceRegistryV2.ListingStatus.Delisted);
        assertEq(services.getListing(id).updatedAt, T0 + 3_000);
    }

    function test_setVerificationForVersion_stampsTime() public {
        vm.warp(T0 + 1_000);
        uint256 id = _publish();
        vm.warp(T0 + 4_000);
        vm.prank(admin);
        services.setVerificationForVersion(id, 1, MANIFEST_1, AgonServiceRegistryV2.Verification.Verified);
        assertEq(services.getListing(id).updatedAt, T0 + 4_000);
    }

    function test_profileUsable_isFalseWhenTheProfileReadFailsForAnotherReason() public {
        AgonServiceRegistryV2 broken = new AgonServiceRegistryV2(admin, address(new BrokenProfiles()), admin);
        assertFalse(broken.profileUsable(42));
    }
}
