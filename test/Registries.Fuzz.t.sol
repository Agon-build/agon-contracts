// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";

contract RegistriesFuzzIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }

    function move(address from, address to, uint256 id) external {
        _transfer(from, to, id);
    }
}

/// @notice Fuzz tests for AgonServiceRegistryV2 and AgonProfileRegistry: versions, scoped
///         verification, service keys, escrow eligibility, profile status and ownership.
contract RegistriesFuzzTest is Test {
    RegistriesFuzzIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    address internal admin = makeAddr("admin");
    address internal verifier = makeAddr("verifier");
    address internal provider = makeAddr("provider");
    uint256 internal constant AGENT = 42;
    bytes32 internal constant MANIFEST = keccak256("manifest-v1");

    function setUp() public {
        identity = new RegistriesFuzzIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), verifier);
        identity.mint(provider, AGENT);
        vm.prank(provider);
        profiles.bindProfile(AGENT, "ipfs://profile");
    }

    function _publish(bytes32 key, AgonServiceRegistryV2.PaymentRail rail) internal returns (uint256 id) {
        vm.prank(provider);
        id = services.publish(AGENT, key, MANIFEST, "ipfs://m1", 1, rail);
    }

    // ---------------------------------------------------------------- service registry

    /// INV-REG-01, INV-REG-02: the version grows by exactly one and always starts Unverified.
    function testFuzz_versionsGrowByOneAndResetVerification(uint8 count, bytes32 seed) public {
        count = uint8(bound(count, 1, 20));
        uint256 id = _publish(keccak256("svc"), AgonServiceRegistryV2.PaymentRail.Escrow);
        bytes32 hash = MANIFEST;
        for (uint256 i = 0; i < count; i++) {
            vm.prank(verifier);
            services.setVerificationForVersion(id, i + 1, hash, AgonServiceRegistryV2.Verification.Verified);
            assertTrue(services.escrowEligible(id));

            hash = keccak256(abi.encode(seed, i));
            vm.prank(provider);
            services.publishVersion(id, hash, "ipfs://next", AgonServiceRegistryV2.PaymentRail.Escrow);

            AgonServiceRegistryV2.Listing memory l = services.getListing(id);
            assertEq(l.version, i + 2);
            assertEq(l.manifestHash, hash);
            assertEq(uint8(l.verification), uint8(AgonServiceRegistryV2.Verification.Unverified));
            assertFalse(services.escrowEligible(id));
            assertEq(services.getVersion(id, i + 2).manifestHash, hash);
        }
    }

    /// INV-REG-03: verification lands only on the current version and manifest hash.
    function testFuzz_verificationIsScopedToCurrentVersion(uint256 version, bytes32 hash, uint8 v) public {
        uint256 id = _publish(keccak256("svc"), AgonServiceRegistryV2.PaymentRail.Escrow);
        v = uint8(bound(v, 0, 5));
        vm.assume(version != 1 || hash != MANIFEST);
        vm.prank(verifier);
        vm.expectRevert(AgonServiceRegistryV2.VerificationScopeChanged.selector);
        services.setVerificationForVersion(id, version, hash, AgonServiceRegistryV2.Verification(v));
    }

    /// Pending and Verified only while Listed; any other value may be recorded at any status.
    function testFuzz_onlyListedListingsCanBeVerified(uint8 status, uint8 v) public {
        status = uint8(bound(status, 1, 2));
        v = uint8(bound(v, 0, 5));
        uint256 id = _publish(keccak256("svc"), AgonServiceRegistryV2.PaymentRail.Escrow);
        vm.prank(provider);
        services.setStatus(id, AgonServiceRegistryV2.ListingStatus(status));

        AgonServiceRegistryV2.Verification verification = AgonServiceRegistryV2.Verification(v);
        bool positive = verification == AgonServiceRegistryV2.Verification.Pending
            || verification == AgonServiceRegistryV2.Verification.Verified;
        vm.prank(verifier);
        if (positive) vm.expectRevert(AgonServiceRegistryV2.VerificationScopeChanged.selector);
        services.setVerificationForVersion(id, 1, MANIFEST, verification);
        assertFalse(services.escrowEligible(id));
    }

    /// INV-REG-04: a service key is used once per agent.
    function testFuzz_serviceKeyUsedOncePerAgent(bytes32 key) public {
        vm.assume(key != bytes32(0));
        _publish(key, AgonServiceRegistryV2.PaymentRail.X402);
        vm.prank(provider);
        vm.expectRevert(AgonServiceRegistryV2.ServiceKeyAlreadyPublished.selector);
        services.publish(AGENT, key, MANIFEST, "ipfs://m1", 1, AgonServiceRegistryV2.PaymentRail.X402);

        // Another agent may use the same key.
        address other = makeAddr("other");
        identity.mint(other, AGENT + 1);
        vm.prank(other);
        services.publish(AGENT + 1, key, MANIFEST, "ipfs://m1", 1, AgonServiceRegistryV2.PaymentRail.X402);
    }

    /// INV-REG-05: escrowEligible needs Listed, Escrow rail, Verified and a usable profile, all four.
    function testFuzz_escrowEligibleNeedsAllFour(bool escrowRail, bool verified, uint8 status, uint8 profile) public {
        status = uint8(bound(status, 0, 2));
        profile = uint8(bound(profile, 0, 2));
        uint256 id = _publish(
            keccak256("svc"),
            escrowRail ? AgonServiceRegistryV2.PaymentRail.Escrow : AgonServiceRegistryV2.PaymentRail.X402
        );
        if (verified) {
            vm.prank(verifier);
            services.setVerificationForVersion(id, 1, MANIFEST, AgonServiceRegistryV2.Verification.Verified);
        }
        if (status != 0) {
            vm.prank(provider);
            services.setStatus(id, AgonServiceRegistryV2.ListingStatus(status));
        }
        if (profile == 1) {
            vm.prank(admin);
            profiles.suspendProfile(AGENT, keccak256("r"));
        } else if (profile == 2) {
            vm.prank(provider);
            profiles.archiveProfile(AGENT);
        }
        assertEq(services.escrowEligible(id), escrowRail && verified && status == 0 && profile == 0);
    }

    function testFuzz_onlyIdentityOwnerPublishesOrChanges(address stranger) public {
        vm.assume(stranger != provider);
        vm.prank(stranger);
        vm.expectRevert(AgonServiceRegistryV2.NotIdentityOwner.selector);
        services.publish(AGENT, keccak256("svc"), MANIFEST, "ipfs://m1", 1, AgonServiceRegistryV2.PaymentRail.X402);

        uint256 id = _publish(keccak256("svc"), AgonServiceRegistryV2.PaymentRail.X402);
        vm.startPrank(stranger);
        vm.expectRevert(AgonServiceRegistryV2.NotIdentityOwner.selector);
        services.publishVersion(id, keccak256("m2"), "ipfs://m2", AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.NotIdentityOwner.selector);
        services.setStatus(id, AgonServiceRegistryV2.ListingStatus.Delisted);
        vm.stopPrank();
    }

    function testFuzz_strangerCannotVerify(address stranger) public {
        vm.assume(stranger != verifier);
        uint256 id = _publish(keccak256("svc"), AgonServiceRegistryV2.PaymentRail.Escrow);
        bytes32 role = services.VERIFIER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        services.setVerificationForVersion(id, 1, MANIFEST, AgonServiceRegistryV2.Verification.Verified);
    }

    /// A new identity owner's version makes it the provider for new jobs.
    function testFuzz_newOwnerVersionMovesProvider(address newOwner) public {
        vm.assume(newOwner != address(0) && newOwner != provider && newOwner.code.length == 0);
        uint256 id = _publish(keccak256("svc"), AgonServiceRegistryV2.PaymentRail.Escrow);
        identity.move(provider, newOwner, AGENT);
        vm.prank(provider);
        vm.expectRevert(AgonServiceRegistryV2.NotIdentityOwner.selector);
        services.publishVersion(id, keccak256("m2"), "ipfs://m2", AgonServiceRegistryV2.PaymentRail.Escrow);
        vm.prank(newOwner);
        services.publishVersion(id, keccak256("m2"), "ipfs://m2", AgonServiceRegistryV2.PaymentRail.Escrow);
        assertEq(services.getListing(id).providerSnapshot, newOwner);
    }

    // ---------------------------------------------------------------- profiles

    /// INV-PRF-01: an Archived profile never changes status again, whatever the admin tries.
    function testFuzz_archivedProfileStaysArchived(bool suspendFirst, bytes32 reason) public {
        if (suspendFirst) {
            vm.prank(admin);
            profiles.suspendProfile(AGENT, reason);
        }
        vm.prank(provider);
        profiles.archiveProfile(AGENT);

        vm.startPrank(admin);
        vm.expectRevert(AgonProfileRegistry.ProfileNotActive.selector);
        profiles.suspendProfile(AGENT, reason);
        vm.expectRevert(AgonProfileRegistry.ProfileNotSuspended.selector);
        profiles.reinstateProfile(AGENT);
        vm.stopPrank();
        assertEq(uint8(profiles.getProfile(AGENT).status), uint8(AgonProfileRegistry.Status.Archived));
    }

    /// INV-PRF-02: only the current identity owner changes a profile.
    function testFuzz_onlyOwnerChangesProfile(address stranger) public {
        vm.assume(stranger != provider);
        vm.startPrank(stranger);
        vm.expectRevert(AgonProfileRegistry.NotIdentityOwner.selector);
        profiles.updateProfile(AGENT, "ipfs://x");
        vm.expectRevert(AgonProfileRegistry.NotIdentityOwner.selector);
        profiles.archiveProfile(AGENT);
        vm.expectRevert(AgonProfileRegistry.NotIdentityOwner.selector);
        profiles.syncOwnership(AGENT);
        vm.stopPrank();
    }

    function testFuzz_strangerCannotSuspend(address stranger) public {
        vm.assume(stranger != admin);
        bytes32 role = profiles.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        profiles.suspendProfile(AGENT, keccak256("r"));
    }

    function testFuzz_metadataUriLength(uint256 length) public {
        length = bound(length, 0, 4096);
        bytes memory uri = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            uri[i] = "a";
        }
        vm.prank(provider);
        if (length == 0 || length > 2048) vm.expectRevert(AgonProfileRegistry.InvalidMetadataURI.selector);
        profiles.updateProfile(AGENT, string(uri));
    }
}
