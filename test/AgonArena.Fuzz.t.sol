// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonArena } from "../src/AgonArena.sol";

contract ArenaFuzzIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @notice Fuzz tests for the AgonArena evaluation lifecycle: request hashes, scores, expiry and
///         the listing scope an evaluation records.
/// @dev Times are absolute (T0), never `block.timestamp` read after a warp.
contract AgonArenaFuzzTest is Test {
    ArenaFuzzIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonArena internal arena;
    address internal admin = makeAddr("admin");
    address internal evaluator = makeAddr("evaluator");
    address internal provider = makeAddr("provider");
    uint256 internal constant T0 = 1_000_000;
    uint64 internal constant EXPIRES = uint64(T0 + 7 days);
    bytes32 internal constant MANIFEST = keccak256("manifest-v1");
    uint256 internal listingId;

    function setUp() public {
        vm.warp(T0);
        identity = new ArenaFuzzIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        arena = new AgonArena(admin, address(profiles), address(services), makeAddr("validation"));
        identity.mint(provider, 42);
        vm.startPrank(provider);
        profiles.bindProfile(42, "ipfs://profile");
        listingId = services.publish(42, keccak256("svc"), MANIFEST, "ipfs://m1", 3, AgonServiceRegistryV2.PaymentRail.X402);
        vm.stopPrank();
        bytes32 evaluatorRole = arena.EVALUATOR_ROLE();
        vm.prank(admin);
        arena.grantRole(evaluatorRole, evaluator);
    }

    function _request(bytes32 requestHash, uint64 expiresAt) internal returns (uint256 id) {
        vm.prank(provider);
        id = arena.requestEvaluation(
            requestHash, listingId, keccak256("cap"), keccak256("eval-v1"), keccak256("task"), expiresAt
        );
    }

    function _submitted(bytes32 requestHash) internal returns (uint256 id) {
        id = _request(requestHash, EXPIRES);
        vm.prank(evaluator);
        arena.startEvaluation(id);
        vm.prank(provider);
        arena.submitEvidence(id, keccak256("evidence"));
    }

    /// INV-ARN-01: a request hash is used at most once.
    function testFuzz_requestHashUsedOnce(bytes32 requestHash) public {
        vm.assume(requestHash != bytes32(0));
        _request(requestHash, EXPIRES);
        vm.prank(provider);
        vm.expectRevert(AgonArena.RequestAlreadyUsed.selector);
        arena.requestEvaluation(
            requestHash, listingId, keccak256("cap"), keccak256("eval-v1"), keccak256("task"), EXPIRES
        );
    }

    /// INV-ARN-02: a score is set once, only on a Submitted evaluation; 50 or more is Verified.
    function testFuzz_scoreDecidesOutcomeOnce(uint8 score, bytes32 response) public {
        vm.assume(response != bytes32(0));
        uint256 id = _submitted(keccak256("req"));
        vm.prank(evaluator);
        if (score > 100) {
            vm.expectRevert(AgonArena.InvalidScore.selector);
            arena.scoreEvaluation(id, score, response);
            return;
        }
        arena.scoreEvaluation(id, score, response);
        AgonArena.Evaluation memory e = arena.getEvaluation(id);
        assertEq(e.score, score);
        assertEq(uint8(e.state), uint8(score >= 50 ? AgonArena.State.Verified : AgonArena.State.Rejected));

        vm.prank(evaluator);
        vm.expectRevert(AgonArena.InvalidState.selector);
        arena.scoreEvaluation(id, score, response);
    }

    function testFuzz_scoreNeedsEvidenceFirst(uint8 score) public {
        score = uint8(bound(score, 0, 100));
        uint256 id = _request(keccak256("req"), EXPIRES);
        vm.prank(evaluator);
        vm.expectRevert(AgonArena.InvalidState.selector);
        arena.scoreEvaluation(id, score, keccak256("resp"));
        vm.prank(evaluator);
        arena.startEvaluation(id);
        vm.prank(evaluator);
        vm.expectRevert(AgonArena.InvalidState.selector);
        arena.scoreEvaluation(id, score, keccak256("resp"));
    }

    /// Expiry closes only Pending and Active evaluations, at or after expiresAt (PRE-03).
    function testFuzz_expiryBoundary(uint256 elapsed, bool started) public {
        elapsed = bound(elapsed, 0, 14 days);
        uint256 id = _request(keccak256("req"), EXPIRES);
        if (started) {
            vm.prank(evaluator);
            arena.startEvaluation(id);
        }
        vm.warp(T0 + elapsed);
        if (T0 + elapsed < EXPIRES) {
            vm.expectRevert(AgonArena.EvaluationNotExpired.selector);
            arena.expireEvaluation(id);
        } else {
            arena.expireEvaluation(id);
            assertEq(uint8(arena.getEvaluation(id).state), uint8(AgonArena.State.Expired));
        }
    }

    function testFuzz_submittedNeverExpires(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 365 days);
        uint256 id = _submitted(keccak256("req"));
        vm.warp(T0 + elapsed);
        vm.expectRevert(AgonArena.InvalidState.selector);
        arena.expireEvaluation(id);
    }

    function testFuzz_expiryMustBeInTheFuture(uint64 expiresAt) public {
        expiresAt = uint64(bound(expiresAt, 0, T0));
        vm.prank(provider);
        vm.expectRevert(AgonArena.InvalidExpiry.selector);
        arena.requestEvaluation(
            keccak256("req"), listingId, keccak256("cap"), keccak256("eval-v1"), keccak256("task"), expiresAt
        );
    }

    /// INV-ARN-03: the evaluation keeps the version and manifest current at request.
    function testFuzz_evaluationKeepsItsScope(bytes32 newManifest) public {
        vm.assume(newManifest != bytes32(0) && newManifest != MANIFEST);
        uint256 id = _request(keccak256("req"), EXPIRES);
        vm.prank(provider);
        services.publishVersion(listingId, newManifest, "ipfs://m2", AgonServiceRegistryV2.PaymentRail.X402);
        AgonArena.Evaluation memory e = arena.getEvaluation(id);
        assertEq(e.listingVersion, 1);
        assertEq(e.manifestHash, MANIFEST);
        assertEq(e.participant, provider);
    }

    function testFuzz_onlyParticipantRequestsAndSubmits(address stranger) public {
        vm.assume(stranger != provider);
        vm.prank(stranger);
        vm.expectRevert(AgonArena.WrongParticipant.selector);
        arena.requestEvaluation(
            keccak256("req"), listingId, keccak256("cap"), keccak256("eval-v1"), keccak256("task"), EXPIRES
        );

        uint256 id = _request(keccak256("req"), EXPIRES);
        vm.prank(evaluator);
        arena.startEvaluation(id);
        vm.prank(stranger);
        vm.expectRevert(AgonArena.WrongParticipant.selector);
        arena.submitEvidence(id, keccak256("evidence"));
    }

    function testFuzz_strangerCannotStartOrScore(address stranger) public {
        vm.assume(stranger != evaluator);
        uint256 id = _request(keccak256("req"), EXPIRES);
        bytes32 role = arena.EVALUATOR_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        arena.startEvaluation(id);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        arena.scoreEvaluation(id, 80, keccak256("resp"));
        vm.stopPrank();
    }

    function testFuzz_delistedListingCannotBeEvaluated(uint8 status) public {
        status = uint8(bound(status, 1, 2));
        vm.prank(provider);
        services.setStatus(listingId, AgonServiceRegistryV2.ListingStatus(status));
        vm.prank(provider);
        vm.expectRevert(AgonArena.ListingNotAvailable.selector);
        arena.requestEvaluation(
            keccak256("req"), listingId, keccak256("cap"), keccak256("eval-v1"), keccak256("task"), EXPIRES
        );
    }
}
