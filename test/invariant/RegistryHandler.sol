// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { AgonProfileRegistry } from "../../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../../src/AgonServiceRegistryV2.sol";
import { InvariantIdentity } from "./EscrowHandler.sol";

/// @notice Drives AgonServiceRegistryV2 and AgonProfileRegistry through random sequences: three
///         agents (two with profiles, one without), listings, new versions, status changes,
///         verification of current and stale versions, profile suspension, reinstatement and
///         archiving, and identity transfers. Calls that revert are skipped.
contract RegistryHandler is Test {
    uint256 public constant MAX_LISTINGS = 10;

    InvariantIdentity public identity;
    AgonProfileRegistry public profiles;
    AgonServiceRegistryV2 public services;
    address public admin = makeAddr("reg-admin");
    address public verifier = makeAddr("reg-verifier");
    address[3] public people = [makeAddr("reg-person-a"), makeAddr("reg-person-b"), makeAddr("reg-person-c")];
    uint256[3] public agents = [uint256(11), 12, 13];

    uint256[] public listingIds;
    uint256 internal nonce;

    /// Last version seen per listing.
    mapping(uint256 => uint256) public lastVersion;
    /// The version and manifest hash last marked Verified per listing.
    mapping(uint256 => uint256) public verifiedVersion;
    mapping(uint256 => bytes32) public verifiedManifest;
    /// Agents whose profile was archived.
    mapping(uint256 => bool) public archived;
    /// Set when a version went down or skipped.
    bool public versionBroken;
    /// Set when a new version did not start Unverified.
    bool public newVersionNotUnverified;
    /// Set when verification succeeded for a version or hash that was not current.
    bool public staleVerificationAccepted;

    mapping(bytes32 => uint256) public calls;

    constructor() {
        identity = new InvariantIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), verifier);
        for (uint256 i = 0; i < 3; i++) {
            identity.mint(people[i], agents[i]);
        }
        // Agents 11 and 12 bind profiles; 13 has none, which may still publish (audit C2).
        vm.prank(people[0]);
        profiles.bindProfile(agents[0], "ipfs://p11");
        vm.prank(people[1]);
        profiles.bindProfile(agents[1], "ipfs://p12");
    }

    function listingCount() external view returns (uint256) {
        return listingIds.length;
    }

    // ---------------------------------------------------------------- listing actions

    function publish(uint256 agentSeed, bool escrowRail) external {
        if (listingIds.length >= MAX_LISTINGS) return;
        uint256 agent = agents[agentSeed % 3];
        address owner = identity.ownerOf(agent);
        vm.prank(owner);
        try services.publish(
            agent,
            keccak256(abi.encode("key", ++nonce)),
            keccak256(abi.encode("manifest", nonce)),
            "ipfs://m",
            1,
            escrowRail ? AgonServiceRegistryV2.PaymentRail.Escrow : AgonServiceRegistryV2.PaymentRail.X402
        ) returns (uint256 id) {
            listingIds.push(id);
            lastVersion[id] = 1;
            if (services.getListing(id).verification != AgonServiceRegistryV2.Verification.Unverified) {
                newVersionNotUnverified = true;
            }
            calls["publish"]++;
        } catch { }
    }

    function publishVersion(uint256 seed, bool asOwner) external {
        (uint256 id, AgonServiceRegistryV2.Listing memory l) = _pick(seed);
        if (id == 0) return;
        address caller = asOwner ? identity.ownerOf(l.agentId) : people[seed % 3];
        vm.prank(caller);
        try services.publishVersion(id, keccak256(abi.encode("manifest", ++nonce)), "ipfs://m2", l.paymentRail) {
            AgonServiceRegistryV2.Listing memory after_ = services.getListing(id);
            if (after_.version != lastVersion[id] + 1) versionBroken = true;
            if (after_.verification != AgonServiceRegistryV2.Verification.Unverified) newVersionNotUnverified = true;
            calls["publishVersion"]++;
        } catch { }
        _record();
    }

    function setStatus(uint256 seed, uint8 status) external {
        (uint256 id, AgonServiceRegistryV2.Listing memory l) = _pick(seed);
        if (id == 0) return;
        vm.prank(identity.ownerOf(l.agentId));
        try services.setStatus(id, AgonServiceRegistryV2.ListingStatus(status % 3)) {
            calls["setStatus"]++;
        } catch { }
    }

    /// Verify the current version, or try a stale version or hash, which must be refused.
    function verify(uint256 seed, uint8 value, bool current, uint256 staleVersion) external {
        (uint256 id, AgonServiceRegistryV2.Listing memory l) = _pick(seed);
        if (id == 0) return;
        AgonServiceRegistryV2.Verification v = AgonServiceRegistryV2.Verification(value % 6);
        uint256 version = current ? l.version : bound(staleVersion, 0, l.version + 2);
        bytes32 hash = current ? l.manifestHash : keccak256(abi.encode("stale", staleVersion));
        vm.prank(verifier);
        try services.setVerificationForVersion(id, version, hash, v) {
            if (version != l.version || hash != l.manifestHash) staleVerificationAccepted = true;
            if (v == AgonServiceRegistryV2.Verification.Verified) {
                verifiedVersion[id] = version;
                verifiedManifest[id] = hash;
            }
            calls["verify"]++;
        } catch { }
    }

    // ---------------------------------------------------------------- profile and identity actions

    function suspendProfile(uint256 agentSeed) external {
        vm.prank(admin);
        try profiles.suspendProfile(agents[agentSeed % 3], keccak256("reason")) {
            calls["suspendProfile"]++;
        } catch { }
    }

    function reinstateProfile(uint256 agentSeed) external {
        vm.prank(admin);
        try profiles.reinstateProfile(agents[agentSeed % 3]) {
            calls["reinstateProfile"]++;
        } catch { }
    }

    function archiveProfile(uint256 agentSeed) external {
        uint256 agent = agents[agentSeed % 3];
        vm.prank(identity.ownerOf(agent));
        try profiles.archiveProfile(agent) {
            archived[agent] = true;
            calls["archiveProfile"]++;
        } catch { }
    }

    function transferIdentity(uint256 agentSeed, uint256 toSeed) external {
        uint256 agent = agents[agentSeed % 3];
        address from = identity.ownerOf(agent);
        address to = people[toSeed % 3];
        if (from == to) return;
        identity.move(from, to, agent);
        calls["transferIdentity"]++;
    }

    // ---------------------------------------------------------------- internals

    function _pick(uint256 seed) internal view returns (uint256 id, AgonServiceRegistryV2.Listing memory l) {
        if (listingIds.length == 0) return (0, l);
        id = listingIds[seed % listingIds.length];
        l = services.getListing(id);
    }

    function _record() internal {
        for (uint256 i = 0; i < listingIds.length; i++) {
            uint256 id = listingIds[i];
            uint256 v = services.getListing(id).version;
            if (v < lastVersion[id]) versionBroken = true;
            lastVersion[id] = v;
        }
    }
}
