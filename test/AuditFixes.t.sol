// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployHelper } from "./utils/DeployHelper.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonArenaV2 } from "../src/AgonArenaV2.sol";
import { AgonArena } from "../src/AgonArena.sol";

contract AuditFixesIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @notice Fixes for KNOWN_ISSUES PRE-01, PRE-03 and PRE-04.
contract AuditFixesTest is Test, DeployHelper {
    AuditFixesIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonArenaV2 internal arena;
    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal evaluator = makeAddr("evaluator");

    function setUp() public {
        identity = new AuditFixesIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        arena = new AgonArenaV2(admin, address(profiles), address(services), makeAddr("validation"), evaluator);
        identity.mint(owner, 7);
        vm.prank(owner);
        profiles.bindProfile(7, "ipfs://p");
    }

    // PRE-01: archiving is final.
    function test_archived_profile_cannot_be_suspended_or_reinstated() public {
        vm.prank(owner);
        profiles.archiveProfile(7);
        vm.startPrank(admin);
        vm.expectRevert(AgonProfileRegistry.ProfileNotActive.selector);
        profiles.suspendProfile(7, keccak256("r"));
        vm.expectRevert(AgonProfileRegistry.ProfileNotSuspended.selector);
        profiles.reinstateProfile(7);
        vm.stopPrank();
        assertEq(uint8(profiles.getProfile(7).status), uint8(AgonProfileRegistry.Status.Archived));
    }

    function test_suspend_twice_is_refused() public {
        vm.startPrank(admin);
        profiles.suspendProfile(7, keccak256("r"));
        vm.expectRevert(AgonProfileRegistry.ProfileNotActive.selector);
        profiles.suspendProfile(7, keccak256("r2"));
        vm.stopPrank();
    }

    // PRE-04: the profile registry refuses zero addresses at deployment.
    function test_profile_registry_refuses_zero_addresses() public {
        vm.expectRevert(AgonProfileRegistry.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonProfileRegistry).creationCode, abi.encode(address(0), address(identity))));
        vm.expectRevert(AgonProfileRegistry.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonProfileRegistry).creationCode, abi.encode(admin, address(0))));
    }

    // PRE-03 (owner decision 2026-11-26): a handed-in evaluation waits for its score.
    function _submittedEvaluation() internal returns (uint256 evaluationId) {
        vm.prank(owner);
        uint256 listingId = services.publish(
            7, keccak256("svc"), keccak256("manifest"), "ipfs://m", 1, AgonServiceRegistryV2.PaymentRail.X402
        );
        vm.prank(owner);
        evaluationId = arena.requestEvaluation(
            keccak256("request"), listingId, keccak256("cap"), keccak256("evaluator-v1"), keccak256("task"),
            uint64(block.timestamp + 1 hours)
        );
        vm.prank(evaluator);
        arena.startEvaluation(evaluationId);
        vm.prank(owner);
        arena.submitEvidence(evaluationId, keccak256("evidence"));
    }

    function test_submitted_evaluation_cannot_be_expired() public {
        uint256 evaluationId = _submittedEvaluation();
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(AgonArena.InvalidState.selector);
        arena.expireEvaluation(evaluationId);

        vm.prank(evaluator);
        arena.scoreEvaluation(evaluationId, 80, keccak256("response"));
        assertEq(uint8(arena.getEvaluation(evaluationId).state), uint8(AgonArena.State.Verified));
    }

    function test_pending_and_active_evaluations_still_expire() public {
        vm.prank(owner);
        uint256 listingId = services.publish(
            7, keccak256("svc2"), keccak256("manifest"), "ipfs://m", 1, AgonServiceRegistryV2.PaymentRail.X402
        );
        vm.prank(owner);
        uint256 pending = arena.requestEvaluation(
            keccak256("r1"), listingId, keccak256("cap"), keccak256("ev"), keccak256("t"), uint64(block.timestamp + 1 hours)
        );
        vm.prank(owner);
        uint256 active = arena.requestEvaluation(
            keccak256("r2"), listingId, keccak256("cap"), keccak256("ev"), keccak256("t"), uint64(block.timestamp + 1 hours)
        );
        vm.prank(evaluator);
        arena.startEvaluation(active);
        vm.warp(block.timestamp + 1 hours);
        arena.expireEvaluation(pending);
        arena.expireEvaluation(active);
        assertEq(uint8(arena.getEvaluation(pending).state), uint8(AgonArena.State.Expired));
        assertEq(uint8(arena.getEvaluation(active).state), uint8(AgonArena.State.Expired));
    }
}
