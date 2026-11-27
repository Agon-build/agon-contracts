// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonArena } from "../src/AgonArena.sol";

contract MutantsArenaIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @notice Tests added after mutation testing (2026-11-26) showed these behaviours were not
///         checked: only the verifier may revoke, scoring stops while paused, the stored
///         validation response hash, and the evidence and expiry events.
contract AgonArenaMutantsTest is Test {
    MutantsArenaIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonArena internal arena;

    address internal admin = makeAddr("admin");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");
    address internal validationRegistry = makeAddr("validation-registry");
    bytes32 internal constant EVIDENCE_ROOT = keccak256("evidence");
    bytes32 internal constant RESPONSE_HASH = keccak256("response");

    function setUp() public {
        identity = new MutantsArenaIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        arena = new AgonArena(admin, address(profiles), address(services), validationRegistry);
        identity.mint(provider, 42);
        vm.startPrank(provider);
        profiles.bindProfile(42, "ipfs://profile");
        services.publish(
            42, keccak256("secure-review"), keccak256("manifest-v1"), "ipfs://manifest-v1", 3, AgonServiceRegistryV2.PaymentRail.X402
        );
        vm.stopPrank();
        vm.startPrank(admin);
        services.setVerificationForVersion(1, 1, keccak256("manifest-v1"), AgonServiceRegistryV2.Verification.Verified);
        arena.grantRole(arena.EVALUATOR_ROLE(), admin);
        arena.grantRole(arena.VERIFIER_ROLE(), admin);
        vm.stopPrank();
    }

    function _active() internal returns (uint256 id) {
        vm.prank(provider);
        id = arena.requestEvaluation(
            keccak256("request-1"),
            1,
            keccak256("capability"),
            keccak256("evaluator-v1"),
            keccak256("hidden-task"),
            uint64(block.timestamp + 7 days)
        );
        vm.prank(admin);
        arena.startEvaluation(id);
    }

    function _submitted() internal returns (uint256 id) {
        id = _active();
        vm.prank(provider);
        arena.submitEvidence(id, EVIDENCE_ROOT);
    }

    function _scored() internal returns (uint256 id) {
        id = _submitted();
        vm.prank(admin);
        arena.scoreEvaluation(id, 80, RESPONSE_HASH);
    }

    function test_revokeEvaluation_onlyVerifier() public {
        uint256 id = _scored();
        bytes32 role = arena.VERIFIER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        arena.revokeEvaluation(id, keccak256("reason"));
        assertEq(uint8(arena.getEvaluation(id).state), uint8(AgonArena.State.Verified));
    }

    function test_scoreEvaluation_refusedWhilePaused() public {
        uint256 id = _submitted();
        vm.startPrank(admin);
        arena.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        arena.scoreEvaluation(id, 80, RESPONSE_HASH);
        vm.stopPrank();
    }

    function test_scoreEvaluation_storesTheResponseHash() public {
        uint256 id = _scored();
        assertEq(arena.getEvaluation(id).validationResponseHash, RESPONSE_HASH);
    }

    function test_submitEvidence_emitsEvidenceSubmitted() public {
        uint256 id = _active();
        vm.expectEmit(true, true, false, true, address(arena));
        emit AgonArena.EvidenceSubmitted(id, EVIDENCE_ROOT, uint64(block.timestamp));
        vm.prank(provider);
        arena.submitEvidence(id, EVIDENCE_ROOT);
    }

    function test_expireEvaluation_emitsEvaluationExpired() public {
        uint256 id = _active();
        vm.warp(block.timestamp + 7 days);
        vm.expectEmit(true, false, false, false, address(arena));
        emit AgonArena.EvaluationExpired(id);
        arena.expireEvaluation(id);
    }
}
