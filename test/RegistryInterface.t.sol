// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { IAgonServiceRegistry } from "../src/interfaces/IAgonServiceRegistry.sol";

contract RegistryInterfaceIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @notice The escrow and the Arena read the V2 registry through IAgonServiceRegistry.
///         These tests pin that the interface decodes exactly what V2 returns.
contract RegistryInterfaceTest is Test {
    RegistryInterfaceIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    address internal admin = makeAddr("admin");
    address internal provider = makeAddr("provider");

    function setUp() public {
        identity = new RegistryInterfaceIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        identity.mint(provider, 42);
        vm.prank(provider);
        profiles.bindProfile(42, "ipfs://profile");
    }

    function test_v2_registry_abi_matches_interface() public {
        vm.prank(provider);
        uint256 id = services.publish(
            42, keccak256("svc"), keccak256("manifest"), "ipfs://manifest", 3, AgonServiceRegistryV2.PaymentRail.Escrow
        );
        vm.prank(admin);
        services.setVerificationForVersion(id, 1, keccak256("manifest"), AgonServiceRegistryV2.Verification.Verified);

        AgonServiceRegistryV2.Listing memory direct = services.getListing(id);
        IAgonServiceRegistry.Listing memory viaInterface = IAgonServiceRegistry(address(services)).getListing(id);

        assertEq(viaInterface.listingId, direct.listingId);
        assertEq(viaInterface.agentId, direct.agentId);
        assertEq(viaInterface.serviceKey, direct.serviceKey);
        assertEq(viaInterface.manifestHash, direct.manifestHash);
        assertEq(viaInterface.manifestURI, direct.manifestURI);
        assertEq(viaInterface.category, direct.category);
        assertEq(uint8(viaInterface.paymentRail), uint8(direct.paymentRail));
        assertEq(viaInterface.version, direct.version);
        assertEq(viaInterface.providerSnapshot, direct.providerSnapshot);
        assertEq(uint8(viaInterface.status), uint8(direct.status));
        assertEq(uint8(viaInterface.verification), uint8(direct.verification));
        assertEq(viaInterface.createdAt, direct.createdAt);
        assertEq(viaInterface.updatedAt, direct.updatedAt);
        assertEq(IAgonServiceRegistry(address(services)).escrowEligible(id), services.escrowEligible(id));
        assertTrue(IAgonServiceRegistry(address(services)).escrowEligible(id));
    }

    function test_enum_orders_match() public pure {
        assertEq(uint8(IAgonServiceRegistry.ListingStatus.Listed), uint8(AgonServiceRegistryV2.ListingStatus.Listed));
        assertEq(uint8(IAgonServiceRegistry.ListingStatus.Suspended), uint8(AgonServiceRegistryV2.ListingStatus.Suspended));
        assertEq(uint8(IAgonServiceRegistry.ListingStatus.Delisted), uint8(AgonServiceRegistryV2.ListingStatus.Delisted));
        assertEq(uint8(IAgonServiceRegistry.Verification.Unverified), uint8(AgonServiceRegistryV2.Verification.Unverified));
        assertEq(uint8(IAgonServiceRegistry.Verification.Pending), uint8(AgonServiceRegistryV2.Verification.Pending));
        assertEq(uint8(IAgonServiceRegistry.Verification.Verified), uint8(AgonServiceRegistryV2.Verification.Verified));
        assertEq(uint8(IAgonServiceRegistry.Verification.Expired), uint8(AgonServiceRegistryV2.Verification.Expired));
        assertEq(uint8(IAgonServiceRegistry.Verification.Suspended), uint8(AgonServiceRegistryV2.Verification.Suspended));
        assertEq(uint8(IAgonServiceRegistry.Verification.Revoked), uint8(AgonServiceRegistryV2.Verification.Revoked));
        assertEq(uint8(IAgonServiceRegistry.PaymentRail.X402), uint8(AgonServiceRegistryV2.PaymentRail.X402));
        assertEq(uint8(IAgonServiceRegistry.PaymentRail.Escrow), uint8(AgonServiceRegistryV2.PaymentRail.Escrow));
    }
}
