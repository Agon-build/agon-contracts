// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployHelper } from "./utils/DeployHelper.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonJobEscrowV2 } from "../src/AgonJobEscrowV2.sol";
import { AgonPrizeVault } from "../src/AgonPrizeVault.sol";
import { AgonArena } from "../src/AgonArena.sol";
import { AgonArenaV2 } from "../src/AgonArenaV2.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { OddReturnToken } from "./mocks/OddReturnToken.sol";
import { FakeServiceRegistry } from "./mocks/FakeServiceRegistry.sol";
import { InvariantIdentity } from "./invariant/EscrowHandler.sol";

/// @notice Every revert and edge branch of the escrow that no other test reaches, one operand of a
///         compound condition per test where it has several. Added for Task 9 (branch coverage
///         and mutation testing).
contract EscrowBranchesTest is Test, DeployHelper {
    InvariantIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonJobEscrowV2 internal escrow;
    MockUSDC internal usdc;
    address internal admin = makeAddr("admin");
    address internal buyer = makeAddr("buyer");
    address internal provider = makeAddr("provider");
    address internal resolver = makeAddr("resolver");
    address internal treasury = makeAddr("treasury");
    uint256 internal constant T0 = 1_000_000;
    uint256 internal listingId;

    function setUp() public {
        vm.warp(T0);
        identity = new InvariantIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        usdc = new MockUSDC();
        escrow = new AgonJobEscrowV2(admin, address(usdc), address(services), resolver, treasury, 24, 500);
        identity.mint(provider, 42);
        vm.startPrank(provider);
        profiles.bindProfile(42, "ipfs://p");
        listingId = services.publish(
            42, keccak256("svc"), keccak256("m"), "ipfs://m", 1, AgonServiceRegistryV2.PaymentRail.Escrow
        );
        vm.stopPrank();
        vm.prank(admin);
        services.setVerificationForVersion(listingId, 1, keccak256("m"), AgonServiceRegistryV2.Verification.Verified);
        usdc.mint(buyer, 1000e6);
        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    uint256 internal nonce;

    function _create() internal returns (uint256) {
        vm.prank(buyer);
        return escrow.createJob(bytes32(++nonce), listingId, keccak256("t"), 10e6, 0);
    }

    function _accepted() internal returns (uint256 id) {
        id = _create();
        vm.prank(provider);
        escrow.acceptJob(id);
    }

    function _submitted() internal returns (uint256 id) {
        id = _accepted();
        vm.prank(provider);
        escrow.submitJob(id, keccak256("d"));
    }

    function _rejected() internal returns (uint256 id) {
        id = _submitted();
        vm.prank(buyer);
        escrow.rejectSubmission(id, keccak256("r"));
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_refuses_each_zero_address() public {
        address u = address(usdc);
        address s = address(services);
        vm.expectRevert(AgonJobEscrowV2.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(address(0), u, s, resolver, treasury, 24, 500)));
        vm.expectRevert(AgonJobEscrowV2.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(admin, address(0), s, resolver, treasury, 24, 500)));
        vm.expectRevert(AgonJobEscrowV2.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(admin, u, address(0), resolver, treasury, 24, 500)));
        vm.expectRevert(AgonJobEscrowV2.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(admin, u, s, address(0), treasury, 24, 500)));
        vm.expectRevert(AgonJobEscrowV2.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(admin, u, s, resolver, address(0), 24, 500)));
        vm.expectRevert(AgonJobEscrowV2.InvalidReviewHours.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(admin, u, s, resolver, treasury, 0, 500)));
        vm.expectRevert(AgonJobEscrowV2.InvalidReviewHours.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(admin, u, s, resolver, treasury, 721, 500)));
        vm.expectRevert(AgonJobEscrowV2.FeeAboveMaximum.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonJobEscrowV2).creationCode, abi.encode(admin, u, s, resolver, treasury, 24, 1001)));
        AgonJobEscrowV2 edge = new AgonJobEscrowV2(admin, u, s, resolver, treasury, 720, 1000);
        assertEq(edge.defaultReviewHours(), 720);
        assertEq(edge.protocolFeeBps(), 1000);
        assertTrue(edge.hasRole(edge.PAUSER_ROLE(), admin));
        assertTrue(edge.hasRole(edge.DEFAULT_ADMIN_ROLE(), admin));
    }

    // ---------------------------------------------------------------- fee schedule

    function test_fee_schedule_refuses_a_second_change_and_an_unchanged_fee() public {
        vm.startPrank(admin);
        vm.expectRevert(AgonJobEscrowV2.FeeUnchanged.selector);
        escrow.scheduleProtocolFeeChange(500);
        escrow.scheduleProtocolFeeChange(700);
        assertEq(escrow.pendingProtocolFeeBps(), 700);
        assertEq(escrow.pendingProtocolFeeEffectiveAt(), T0 + 2 days);
        vm.expectRevert(AgonJobEscrowV2.FeeChangePending.selector);
        escrow.scheduleProtocolFeeChange(800);
        escrow.cancelProtocolFeeChange();
        assertEq(escrow.pendingProtocolFeeBps(), 0);
        assertEq(escrow.pendingProtocolFeeEffectiveAt(), 0);
        vm.expectRevert(AgonJobEscrowV2.NoPendingFeeChange.selector);
        escrow.cancelProtocolFeeChange();
        vm.stopPrank();
        vm.expectRevert(AgonJobEscrowV2.NoPendingFeeChange.selector);
        escrow.applyProtocolFeeChange();
        assertEq(escrow.protocolFeeBps(), 500);
    }

    function test_fee_change_applies_exactly_at_its_time() public {
        vm.prank(admin);
        escrow.scheduleProtocolFeeChange(1000);
        vm.warp(T0 + 2 days - 1);
        vm.expectRevert(AgonJobEscrowV2.FeeChangeTimelocked.selector);
        escrow.applyProtocolFeeChange();
        vm.warp(T0 + 2 days);
        escrow.applyProtocolFeeChange();
        assertEq(escrow.protocolFeeBps(), 1000);
        assertEq(escrow.pendingProtocolFeeEffectiveAt(), 0);
    }

    // ---------------------------------------------------------------- createJob

    function test_createJob_refuses_empty_inputs() public {
        vm.startPrank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidReference.selector);
        escrow.createJob(bytes32(0), listingId, keccak256("t"), 1e6, 0);
        vm.expectRevert(AgonJobEscrowV2.ZeroHash.selector);
        escrow.createJob(keccak256("r"), listingId, bytes32(0), 1e6, 0);
        vm.expectRevert(AgonJobEscrowV2.ZeroAmount.selector);
        escrow.createJob(keccak256("r"), listingId, keccak256("t"), 0, 0);
        vm.stopPrank();
    }

    function test_createJob_refuses_a_listing_with_an_empty_snapshot() public {
        FakeServiceRegistry fake = new FakeServiceRegistry();
        AgonJobEscrowV2 e = new AgonJobEscrowV2(admin, address(usdc), address(fake), resolver, treasury, 24, 500);
        vm.prank(buyer);
        usdc.approve(address(e), type(uint256).max);

        fake.set(address(0), keccak256("m"), 1);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidListingSnapshot.selector);
        e.createJob(keccak256("a"), 1, keccak256("t"), 1e6, 0);

        fake.set(provider, bytes32(0), 1);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidListingSnapshot.selector);
        e.createJob(keccak256("b"), 1, keccak256("t"), 1e6, 0);

        fake.set(provider, keccak256("m"), 0);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidListingSnapshot.selector);
        e.createJob(keccak256("c"), 1, keccak256("t"), 1e6, 0);

        fake.set(provider, keccak256("m"), 1);
        vm.prank(buyer);
        uint256 id = e.createJob(keccak256("d"), 1, keccak256("t"), 1e6, 0);
        assertEq(id, 1);
    }

    function test_createJob_numbers_jobs_from_one() public {
        assertEq(_create(), 1);
        assertEq(_create(), 2);
    }

    // ---------------------------------------------------------------- provider side

    function test_acceptJob_twice_is_refused() public {
        uint256 id = _accepted();
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.acceptJob(id);
    }

    function test_submitJob_refusals() public {
        uint256 id = _create();
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.submitJob(id, keccak256("d"));

        vm.prank(provider);
        escrow.acceptJob(id);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.NotProvider.selector);
        escrow.submitJob(id, keccak256("d"));
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.ZeroHash.selector);
        escrow.submitJob(id, bytes32(0));

        vm.warp(T0 + 24 hours + 1);
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.AcceptanceWindowClosed.selector);
        escrow.submitJob(id, keccak256("d"));
    }

    function test_submitJob_at_the_last_second_sets_the_review_deadline() public {
        uint256 id = _accepted();
        vm.warp(T0 + 24 hours);
        vm.prank(provider);
        escrow.submitJob(id, keccak256("d"));
        AgonJobEscrowV2.Job memory job = escrow.getJob(id);
        assertEq(job.submittedAt, T0 + 24 hours);
        assertEq(job.reviewDeadline, T0 + 48 hours);
        assertEq(job.deliverableHash, keccak256("d"));
    }

    // ---------------------------------------------------------------- buyer side

    function test_acceptSubmission_refusals() public {
        uint256 id = _accepted();
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.acceptSubmission(id);

        vm.prank(provider);
        escrow.submitJob(id, keccak256("d"));
        vm.warp(T0 + 24 hours + 1);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.ReviewWindowClosed.selector);
        escrow.acceptSubmission(id);
    }

    function test_acceptSubmission_at_the_review_deadline_pays() public {
        uint256 id = _submitted();
        vm.warp(T0 + 24 hours);
        vm.prank(buyer);
        escrow.acceptSubmission(id);
        assertEq(usdc.balanceOf(provider), 10e6);
        assertEq(usdc.balanceOf(treasury), 0.5e6);
    }

    function test_autoAccept_needs_a_submitted_job() public {
        uint256 id = _accepted();
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.autoAccept(id);
    }

    function test_rejectSubmission_refusals() public {
        uint256 id = _accepted();
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.rejectSubmission(id, keccak256("r"));
        vm.prank(provider);
        escrow.submitJob(id, keccak256("d"));
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.ZeroHash.selector);
        escrow.rejectSubmission(id, bytes32(0));
        vm.prank(buyer);
        escrow.rejectSubmission(id, keccak256("r"));
        assertEq(escrow.rejectedAt(id), T0);
    }

    function test_openDispute_refusals() public {
        uint256 id = _submitted();
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.openDispute(id, keccak256("x"));
        vm.prank(buyer);
        escrow.rejectSubmission(id, keccak256("r"));
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.ZeroHash.selector);
        escrow.openDispute(id, bytes32(0));
        vm.warp(T0 + 7 days);
        vm.prank(buyer);
        escrow.openDispute(id, keccak256("x"));
        assertEq(escrow.disputedAt(id), T0 + 7 days);
    }

    function test_settlement_paths_refuse_the_wrong_status() public {
        uint256 id = _submitted();
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.failJob(id);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.claimRefundAfterRejection(id);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.exitStaleDispute(id);
        vm.prank(resolver);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.resolveDispute(id, true);
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.acceptRejection(id);
        vm.prank(stranger());
        vm.expectRevert(AgonJobEscrowV2.NotParty.selector);
        escrow.exitStaleDispute(id);
    }

    function stranger() internal returns (address) {
        return makeAddr("stranger");
    }

    function test_window_edges_for_rejection_and_dispute() public {
        uint256 id = _rejected();
        vm.warp(T0 + 7 days);
        vm.expectRevert(AgonJobEscrowV2.RejectionWindowOpen.selector);
        escrow.claimRefundAfterRejection(id);
        vm.prank(provider);
        escrow.openDispute(id, keccak256("x"));
        vm.warp(T0 + 7 days + 14 days);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.ResolverWindowOpen.selector);
        escrow.exitStaleDispute(id);
        vm.prank(resolver);
        escrow.resolveDispute(id, false);
        assertEq(usdc.balanceOf(buyer), 1000e6);
    }

    function test_failJob_at_the_deadline_is_refused_and_one_second_later_refunds() public {
        uint256 id = _accepted();
        vm.warp(T0 + 24 hours);
        vm.expectRevert(AgonJobEscrowV2.AcceptanceWindowOpen.selector);
        escrow.failJob(id);
        vm.warp(T0 + 24 hours + 1);
        escrow.failJob(id);
        assertEq(usdc.balanceOf(buyer), 1000e6);
        assertEq(uint8(escrow.getJob(id).status), uint8(AgonJobEscrowV2.Status.Failed));
    }

    // ---------------------------------------------------------------- admin and views

    function test_setTreasury_refuses_zero_and_moves_fees() public {
        vm.prank(admin);
        vm.expectRevert(AgonJobEscrowV2.ZeroAddress.selector);
        escrow.setTreasury(address(0));
        address next = makeAddr("next-treasury");
        vm.prank(admin);
        escrow.setTreasury(next);
        assertEq(escrow.treasury(), next);
        uint256 id = _submitted();
        vm.prank(buyer);
        escrow.acceptSubmission(id);
        assertEq(usdc.balanceOf(next), 0.5e6);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_missing_job_is_refused() public {
        vm.expectRevert(AgonJobEscrowV2.JobMissing.selector);
        escrow.getJob(1);
        vm.expectRevert(AgonJobEscrowV2.JobMissing.selector);
        escrow.escrowedAmount(1);
        vm.expectRevert(AgonJobEscrowV2.JobMissing.selector);
        escrow.effectiveAcceptanceDeadline(1);
        vm.expectRevert(AgonJobEscrowV2.JobMissing.selector);
        escrow.failJob(1);
    }

    function test_withdrawCredit_with_nothing_is_refused() public {
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.NoCredit.selector);
        escrow.withdrawCredit();
    }

    function test_pause_and_unpause_track_paused_time() public {
        uint256 id = _create();
        vm.prank(admin);
        escrow.pause();
        vm.warp(T0 + 5 hours);
        assertEq(escrow.effectiveAcceptanceDeadline(id), T0 + 29 hours);
        vm.prank(admin);
        escrow.unpause();
        assertEq(escrow.effectiveAcceptanceDeadline(id), T0 + 29 hours);
        vm.warp(T0 + 10 hours);
        assertEq(escrow.effectiveAcceptanceDeadline(id), T0 + 29 hours);
    }

    // ---------------------------------------------------------------- every arm of _send

    function _oddEscrow() internal returns (AgonJobEscrowV2 e, OddReturnToken t, uint256 id) {
        t = new OddReturnToken();
        e = new AgonJobEscrowV2(admin, address(t), address(services), resolver, treasury, 24, 500);
        t.mint(buyer, 100e6);
        vm.prank(buyer);
        t.approve(address(e), type(uint256).max);
        vm.prank(buyer);
        id = e.createJob(keccak256("odd"), listingId, keccak256("t"), 10e6, 0);
        vm.startPrank(provider);
        e.acceptJob(id);
        e.submitJob(id, keccak256("d"));
        vm.stopPrank();
    }

    function test_send_pays_a_token_that_returns_no_data() public {
        (AgonJobEscrowV2 e, OddReturnToken t, uint256 id) = _oddEscrow();
        t.setMode(OddReturnToken.Mode.NoReturn);
        vm.prank(buyer);
        e.acceptSubmission(id);
        assertEq(t.balanceOf(provider), 10e6);
        assertEq(e.totalCredits(), 0);
    }

    function test_send_credits_a_transfer_that_returns_false() public {
        (AgonJobEscrowV2 e, OddReturnToken t, uint256 id) = _oddEscrow();
        t.setMode(OddReturnToken.Mode.ReturnFalse);
        vm.prank(buyer);
        e.acceptSubmission(id);
        assertEq(t.balanceOf(provider), 0);
        assertEq(e.credits(provider), 10e6);
        assertEq(e.credits(treasury), 0.5e6);
        assertEq(e.totalCredits(), 10.5e6);
    }

    function test_send_credits_a_transfer_that_returns_short_data() public {
        (AgonJobEscrowV2 e, OddReturnToken t, uint256 id) = _oddEscrow();
        t.setMode(OddReturnToken.Mode.ShortReturn);
        vm.prank(buyer);
        e.acceptSubmission(id);
        // The token moved the money but did not answer properly, so the escrow cannot know it was
        // paid and credits it too. withdrawCredit then pays from what is left.
        assertEq(e.credits(provider), 10e6);
    }

    function test_send_credits_when_the_token_has_no_code() public {
        (AgonJobEscrowV2 e, OddReturnToken t, uint256 id) = _oddEscrow();
        vm.etch(address(t), "");
        vm.prank(buyer);
        e.acceptSubmission(id);
        assertEq(e.credits(provider), 10e6);
        assertEq(e.credits(treasury), 0.5e6);
    }

    function test_withdrawCredit_after_the_token_recovers() public {
        (AgonJobEscrowV2 e, OddReturnToken t, uint256 id) = _oddEscrow();
        t.setMode(OddReturnToken.Mode.ReturnFalse);
        vm.prank(buyer);
        e.acceptSubmission(id);
        t.setMode(OddReturnToken.Mode.Standard);
        vm.prank(provider);
        e.withdrawCredit();
        assertEq(t.balanceOf(provider), 10e6);
        assertEq(e.credits(provider), 0);
        assertEq(e.totalCredits(), 0.5e6);
    }
}

/// @notice Every revert and edge branch of the prize vault that no other test reaches.
contract VaultBranchesTest is Test, DeployHelper {
    AgonPrizeVault internal vault;
    MockUSDC internal usdc;
    address internal admin = makeAddr("admin");
    address internal sponsor = makeAddr("sponsor");
    address internal treasury = makeAddr("treasury");
    bytes32 internal constant POOL = keccak256("pool");
    uint256 internal constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        usdc = new MockUSDC();
        vault = new AgonPrizeVault(admin, address(usdc), treasury);
        usdc.mint(sponsor, 10_000e6);
        vm.prank(sponsor);
        usdc.approve(address(vault), type(uint256).max);
        bytes32 role = vault.POOL_OPERATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(role, sponsor);
    }

    function _leaf(uint256 i, address who, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(i, who, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _fund() internal {
        vm.prank(sponsor);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Syndicate, 3, sponsor, 1000e6, 500);
    }

    function test_constructor_refuses_each_zero_address() public {
        vm.expectRevert(AgonPrizeVault.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonPrizeVault).creationCode, abi.encode(address(0), address(usdc), treasury)));
        vm.expectRevert(AgonPrizeVault.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonPrizeVault).creationCode, abi.encode(admin, address(0), treasury)));
        vm.expectRevert(AgonPrizeVault.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonPrizeVault).creationCode, abi.encode(admin, address(usdc), address(0))));
    }

    function test_createPool_refusals_and_record() public {
        vm.startPrank(sponsor);
        vm.expectRevert(AgonPrizeVault.ZeroHash.selector);
        vault.createPool(bytes32(0), AgonPrizeVault.PoolKind.Arena, 1, sponsor, 1e6, 0);
        vm.expectRevert(AgonPrizeVault.ZeroAmount.selector);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, sponsor, 0, 0);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Syndicate, 3, sponsor, 1000e6, 1000);
        vm.expectRevert(AgonPrizeVault.PoolAlreadyExists.selector);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, sponsor, 1e6, 0);
        vm.stopPrank();
        AgonPrizeVault.Pool memory p = vault.getPool(POOL);
        assertEq(p.poolKey, POOL);
        assertEq(uint8(p.kind), uint8(AgonPrizeVault.PoolKind.Syndicate));
        assertEq(p.sourceId, 3);
        assertEq(p.fee, 100e6);
        assertEq(usdc.balanceOf(treasury), 100e6);
        assertEq(vault.fundedAt(POOL), T0);
    }

    function test_publishPayoutRoot_refusals() public {
        _fund();
        vm.startPrank(sponsor);
        vm.expectRevert(AgonPrizeVault.InvalidRoot.selector);
        vault.publishPayoutRoot(POOL, bytes32(0), 1e6, uint64(T0 + 1));
        vm.expectRevert(AgonPrizeVault.InvalidRoot.selector);
        vault.publishPayoutRoot(POOL, keccak256("r"), 0, uint64(T0 + 1));
        vm.expectRevert(AgonPrizeVault.ClaimWindowClosed.selector);
        vault.publishPayoutRoot(POOL, keccak256("r"), 1e6, uint64(T0));
        vault.publishPayoutRoot(POOL, keccak256("r"), 1000e6, uint64(T0 + 1));
        vm.expectRevert(AgonPrizeVault.InvalidState.selector);
        vault.publishPayoutRoot(POOL, keccak256("r"), 1e6, uint64(T0 + 1));
        vm.stopPrank();
        assertEq(vault.getPool(POOL).payoutTotal, 1000e6);
        assertEq(vault.getPool(POOL).claimDeadline, T0 + 1);
    }

    function test_publish_at_the_root_deadline_works() public {
        _fund();
        vm.warp(T0 + 30 days);
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, keccak256("r"), 1e6, uint64(T0 + 31 days));
    }

    function test_claim_refusals() public {
        address alice = makeAddr("alice");
        bytes32 la = _leaf(0, alice, 600e6);
        bytes32 lb = _leaf(1, makeAddr("bob"), 500e6);
        _fund();
        vm.expectRevert(AgonPrizeVault.InvalidState.selector);
        vault.claim(POOL, 0, alice, 600e6, _proof(lb));
        vm.prank(sponsor);
        // The root holds 1,100 but only 1,000 may be paid: the second claim must stop.
        vault.publishPayoutRoot(POOL, _pair(la, lb), 1000e6, uint64(T0 + 7 days));
        vm.expectRevert(AgonPrizeVault.ZeroAddress.selector);
        vault.claim(POOL, 0, address(0), 600e6, _proof(lb));
        vm.expectRevert(AgonPrizeVault.ZeroAmount.selector);
        vault.claim(POOL, 0, alice, 0, _proof(lb));
        vault.claim(POOL, 0, alice, 600e6, _proof(lb));
        assertTrue(vault.isClaimed(POOL, 0));
        assertFalse(vault.isClaimed(POOL, 1));
        vm.expectRevert(AgonPrizeVault.PayoutExceedsPrincipal.selector);
        vault.claim(POOL, 1, makeAddr("bob"), 500e6, _proof(la));
    }

    function test_claim_at_the_deadline_works() public {
        address alice = makeAddr("alice");
        bytes32 la = _leaf(0, alice, 600e6);
        bytes32 lb = _leaf(1, makeAddr("bob"), 300e6);
        _fund();
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, _pair(la, lb), 900e6, uint64(T0 + 7 days));
        vm.warp(T0 + 7 days);
        vault.claim(POOL, 0, alice, 600e6, _proof(lb));
        assertEq(usdc.balanceOf(alice), 600e6);
    }

    function test_claimed_bits_are_per_index() public {
        address alice = makeAddr("alice");
        bytes32 la = _leaf(300, alice, 1e6);
        bytes32 lb = _leaf(1, makeAddr("bob"), 1e6);
        _fund();
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, _pair(la, lb), 2e6, uint64(T0 + 7 days));
        vault.claim(POOL, 300, alice, 1e6, _proof(lb));
        assertTrue(vault.isClaimed(POOL, 300));
        assertFalse(vault.isClaimed(POOL, 44));
        assertFalse(vault.isClaimed(POOL, 1));
        vault.claim(POOL, 1, makeAddr("bob"), 1e6, _proof(la));
        assertTrue(vault.isClaimed(POOL, 1));
    }

    function test_refunds_refuse_the_wrong_state() public {
        _fund();
        vm.expectRevert(AgonPrizeVault.InvalidState.selector);
        vault.refundRemaining(POOL);
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, keccak256("r"), 1e6, uint64(T0 + 1));
        vm.warp(T0 + 40 days);
        vm.expectRevert(AgonPrizeVault.InvalidState.selector);
        vault.refundUnpublished(POOL);
        vault.refundRemaining(POOL);
        vm.expectRevert(AgonPrizeVault.InvalidState.selector);
        vault.refundRemaining(POOL);
        assertEq(uint8(vault.getPool(POOL).state), uint8(AgonPrizeVault.State.Closed));
    }

    function test_refundUnpublished_at_the_deadline_is_refused() public {
        _fund();
        vm.warp(T0 + 30 days);
        vm.expectRevert(AgonPrizeVault.RootPublishWindowOpen.selector);
        vault.refundUnpublished(POOL);
        vm.warp(T0 + 30 days + 1);
        vault.refundUnpublished(POOL);
        assertEq(usdc.balanceOf(sponsor), 10_000e6 - 50e6);
    }

    function test_views_and_missing_pool() public {
        _fund();
        assertEq(vault.effectiveClaimDeadline(POOL), 0);
        vm.expectRevert(AgonPrizeVault.PoolMissing.selector);
        vault.getPool(keccak256("none"));
        vm.expectRevert(AgonPrizeVault.PoolMissing.selector);
        vault.rootPublishDeadline(keccak256("none"));
        vm.expectRevert(AgonPrizeVault.PoolMissing.selector);
        vault.effectiveClaimDeadline(keccak256("none"));
    }

    function test_deadlines_move_while_paused() public {
        _fund();
        vm.prank(admin);
        vault.pause();
        vm.warp(T0 + 3 days);
        assertEq(vault.rootPublishDeadline(POOL), T0 + 33 days);
        vm.prank(admin);
        vault.unpause();
        assertEq(vault.rootPublishDeadline(POOL), T0 + 33 days);
    }

    function test_setTreasury_refuses_zero_and_switches() public {
        vm.prank(admin);
        vm.expectRevert(AgonPrizeVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
        address next = makeAddr("next");
        vm.prank(admin);
        vault.setTreasury(next);
        assertEq(vault.treasury(), next);
        _fund();
        assertEq(usdc.balanceOf(next), 50e6);
    }

    function test_withdrawCredit_with_nothing_is_refused() public {
        vm.expectRevert(AgonPrizeVault.NoCredit.selector);
        vault.withdrawCredit();
    }

    function _oddVault(OddReturnToken.Mode m) internal returns (AgonPrizeVault v, OddReturnToken t, address alice) {
        t = new OddReturnToken();
        v = new AgonPrizeVault(admin, address(t), treasury);
        t.mint(sponsor, 1000e6);
        vm.prank(sponsor);
        t.approve(address(v), type(uint256).max);
        bytes32 role = v.POOL_OPERATOR_ROLE();
        vm.prank(admin);
        v.grantRole(role, sponsor);
        alice = makeAddr("alice");
        bytes32 la = _leaf(0, alice, 600e6);
        bytes32 lb = _leaf(1, makeAddr("bob"), 300e6);
        vm.startPrank(sponsor);
        v.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, sponsor, 1000e6, 0);
        v.publishPayoutRoot(POOL, _pair(la, lb), 900e6, uint64(T0 + 7 days));
        vm.stopPrank();
        t.setMode(m);
        v.claim(POOL, 0, alice, 600e6, _proof(lb));
    }

    function test_send_arms() public {
        (AgonPrizeVault v1, OddReturnToken t1, address alice) = _oddVault(OddReturnToken.Mode.NoReturn);
        assertEq(t1.balanceOf(alice), 600e6);
        assertEq(v1.totalCredits(), 0);
        (AgonPrizeVault v2,,) = _oddVault(OddReturnToken.Mode.ReturnFalse);
        assertEq(v2.credits(alice), 600e6);
        assertEq(v2.totalCredits(), 600e6);
        (AgonPrizeVault v3,,) = _oddVault(OddReturnToken.Mode.ShortReturn);
        assertEq(v3.credits(alice), 600e6);
    }
}

/// @notice Every revert and edge branch of the two registries that no other test reaches.
contract RegistryBranchesTest is Test {
    InvariantIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");

    function setUp() public {
        identity = new InvariantIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        identity.mint(owner, 7);
        identity.mint(owner, 8); // identity 8 never binds a profile
        vm.prank(owner);
        profiles.bindProfile(7, "ipfs://p");
    }

    function test_currentOwner_of_zero_and_unknown_ids() public view {
        assertEq(profiles.currentOwner(0), address(0));
        assertEq(profiles.currentOwner(999), address(0));
        assertEq(profiles.currentOwner(7), owner);
    }

    function test_owner_actions_on_unknown_identity() public {
        vm.startPrank(owner);
        vm.expectRevert(AgonProfileRegistry.IdentityDoesNotExist.selector);
        profiles.updateProfile(999, "ipfs://x");
        vm.expectRevert(AgonProfileRegistry.ZeroAgentId.selector);
        profiles.bindProfile(0, "ipfs://x");
        vm.stopPrank();
    }

    function test_profile_actions_without_a_profile() public {
        vm.startPrank(owner);
        vm.expectRevert(AgonProfileRegistry.MissingIdentity.selector);
        profiles.updateProfile(8, "ipfs://x");
        vm.expectRevert(AgonProfileRegistry.MissingIdentity.selector);
        profiles.syncOwnership(8);
        vm.expectRevert(AgonProfileRegistry.MissingIdentity.selector);
        profiles.archiveProfile(8);
        vm.stopPrank();
        vm.startPrank(admin);
        vm.expectRevert(AgonProfileRegistry.MissingIdentity.selector);
        profiles.suspendProfile(8, keccak256("r"));
        vm.expectRevert(AgonProfileRegistry.MissingIdentity.selector);
        profiles.reinstateProfile(8);
        vm.stopPrank();
        vm.expectRevert(AgonProfileRegistry.MissingIdentity.selector);
        profiles.getProfile(8);
    }

    function test_profile_updates_record_the_caller() public {
        address next = makeAddr("next");
        identity.move(owner, next, 7);
        vm.prank(next);
        profiles.syncOwnership(7);
        assertEq(profiles.getProfile(7).ownerSnapshot, next);
        vm.prank(next);
        profiles.updateProfile(7, "ipfs://new");
        assertEq(profiles.getProfile(7).metadataURI, "ipfs://new");
        vm.prank(admin);
        profiles.suspendProfile(7, keccak256("why"));
        assertEq(profiles.getProfile(7).suspensionReason, keccak256("why"));
        vm.prank(admin);
        profiles.reinstateProfile(7);
        assertEq(profiles.getProfile(7).suspensionReason, bytes32(0));
    }

    function test_publish_refusals() public {
        vm.startPrank(owner);
        vm.expectRevert(AgonServiceRegistryV2.InvalidServiceKey.selector);
        services.publish(7, bytes32(0), keccak256("m"), "u", 1, AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.InvalidManifest.selector);
        services.publish(7, keccak256("k"), bytes32(0), "u", 1, AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.InvalidManifest.selector);
        services.publish(7, keccak256("k"), keccak256("m"), "", 1, AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.InvalidCategory.selector);
        services.publish(7, keccak256("k"), keccak256("m"), "u", 0, AgonServiceRegistryV2.PaymentRail.X402);
        uint256 id = services.publish(7, keccak256("k"), keccak256("m"), "u", 5, AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.InvalidManifest.selector);
        services.publishVersion(id, bytes32(0), "u2", AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.InvalidManifest.selector);
        services.publishVersion(id, keccak256("m2"), "", AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.ListingMissing.selector);
        services.publishVersion(99, keccak256("m2"), "u2", AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.ListingMissing.selector);
        services.setStatus(99, AgonServiceRegistryV2.ListingStatus.Delisted);
        vm.stopPrank();
        AgonServiceRegistryV2.Listing memory l = services.getListing(id);
        assertEq(l.category, 5);
        assertEq(l.agentId, 7);
        assertEq(l.serviceKey, keccak256("k"));
        assertEq(l.manifestURI, "u");
        assertEq(id, 1);
    }

    function test_missing_listing_and_version() public {
        vm.prank(admin);
        vm.expectRevert(AgonServiceRegistryV2.ListingMissing.selector);
        services.setVerificationForVersion(1, 1, keccak256("m"), AgonServiceRegistryV2.Verification.Verified);
        vm.expectRevert(AgonServiceRegistryV2.ListingMissing.selector);
        services.getListing(1);
        vm.expectRevert(AgonServiceRegistryV2.InvalidVersion.selector);
        services.getVersion(1, 1);
        vm.prank(owner);
        uint256 id = services.publish(7, keccak256("k"), keccak256("m"), "u", 1, AgonServiceRegistryV2.PaymentRail.X402);
        vm.expectRevert(AgonServiceRegistryV2.InvalidVersion.selector);
        services.getVersion(id, 2);
        AgonServiceRegistryV2.Version memory v = services.getVersion(id, 1);
        assertEq(v.manifestHash, keccak256("m"));
        assertEq(v.providerSnapshot, owner);
        assertFalse(services.escrowEligible(999));
    }

    function test_setVerification_is_closed() public {
        vm.expectRevert(AgonServiceRegistryV2.ScopedVerificationRequired.selector);
        services.setVerification(1, AgonServiceRegistryV2.Verification.Verified);
    }
}

/// @notice Every revert and edge branch of the Arena that no other test reaches.
contract ArenaBranchesTest is Test, DeployHelper {
    InvariantIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonArena internal arena;
    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal validation = makeAddr("validation");
    uint256 internal constant T0 = 1_000_000;
    uint64 internal constant EXP = uint64(T0 + 1 days);
    uint256 internal listingId;

    function setUp() public {
        vm.warp(T0);
        identity = new InvariantIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        arena = new AgonArena(admin, address(profiles), address(services), validation);
        identity.mint(owner, 7);
        vm.startPrank(owner);
        profiles.bindProfile(7, "ipfs://p");
        listingId = services.publish(7, keccak256("k"), keccak256("m"), "u", 1, AgonServiceRegistryV2.PaymentRail.X402);
        vm.stopPrank();
        bytes32 role = arena.EVALUATOR_ROLE();
        vm.prank(admin);
        arena.grantRole(role, admin);
    }

    function _request() internal returns (uint256) {
        vm.prank(owner);
        return arena.requestEvaluation(keccak256("req"), listingId, keccak256("c"), keccak256("e"), keccak256("t"), EXP);
    }

    function test_constructors_refuse_each_zero_address() public {
        address p = address(profiles);
        address s = address(services);
        vm.expectRevert(AgonArena.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonArena).creationCode, abi.encode(address(0), p, s, validation)));
        vm.expectRevert(AgonArena.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonArena).creationCode, abi.encode(admin, address(0), s, validation)));
        vm.expectRevert(AgonArena.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonArena).creationCode, abi.encode(admin, p, address(0), validation)));
        vm.expectRevert(AgonArena.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonArena).creationCode, abi.encode(admin, p, s, address(0))));
        vm.expectRevert(AgonArena.ZeroAddress.selector);
        this.deployOrRevert(abi.encodePacked(type(AgonArenaV2).creationCode, abi.encode(admin, p, s, validation, address(0))));
        AgonArenaV2 v2 = new AgonArenaV2(admin, p, s, validation, owner);
        assertTrue(v2.hasRole(v2.EVALUATOR_ROLE(), owner));
        assertTrue(v2.hasRole(v2.VERIFIER_ROLE(), admin));
        assertEq(v2.validationRegistry(), validation);
    }

    function test_request_refuses_each_zero_hash() public {
        vm.startPrank(owner);
        vm.expectRevert(AgonArena.ZeroHash.selector);
        arena.requestEvaluation(bytes32(0), listingId, keccak256("c"), keccak256("e"), keccak256("t"), EXP);
        vm.expectRevert(AgonArena.ZeroHash.selector);
        arena.requestEvaluation(keccak256("r"), listingId, bytes32(0), keccak256("e"), keccak256("t"), EXP);
        vm.expectRevert(AgonArena.ZeroHash.selector);
        arena.requestEvaluation(keccak256("r"), listingId, keccak256("c"), bytes32(0), keccak256("t"), EXP);
        vm.expectRevert(AgonArena.ZeroHash.selector);
        arena.requestEvaluation(keccak256("r"), listingId, keccak256("c"), keccak256("e"), bytes32(0), EXP);
        vm.stopPrank();
    }

    function test_request_records_everything() public {
        uint256 id = _request();
        assertEq(id, 1);
        AgonArena.Evaluation memory e = arena.getEvaluation(id);
        assertEq(e.agentId, 7);
        assertEq(e.category, 1);
        assertEq(e.capabilityHash, keccak256("c"));
        assertEq(e.evaluatorVersionHash, keccak256("e"));
        assertEq(e.taskCommitment, keccak256("t"));
        assertEq(e.validationRequestHash, keccak256("req"));
        assertEq(e.requestedAt, T0);
        assertEq(e.expiresAt, EXP);
        assertEq(arena.evaluationByRequestHash(keccak256("req")), id);
    }

    function test_start_and_submit_after_expiry_are_refused() public {
        uint256 id = _request();
        vm.warp(EXP);
        vm.prank(admin);
        vm.expectRevert(AgonArena.InvalidExpiry.selector);
        arena.startEvaluation(id);

        vm.warp(T0);
        uint256 id2;
        vm.prank(owner);
        id2 = arena.requestEvaluation(keccak256("req2"), listingId, keccak256("c"), keccak256("e"), keccak256("t"), EXP);
        vm.prank(owner);
        vm.expectRevert(AgonArena.InvalidState.selector);
        arena.submitEvidence(id2, keccak256("ev"));
        vm.prank(admin);
        arena.startEvaluation(id2);
        vm.prank(owner);
        vm.expectRevert(AgonArena.ZeroHash.selector);
        arena.submitEvidence(id2, bytes32(0));
        vm.warp(EXP);
        vm.prank(owner);
        vm.expectRevert(AgonArena.InvalidExpiry.selector);
        arena.submitEvidence(id2, keccak256("ev"));
    }

    function test_score_and_revoke_edges() public {
        uint256 id = _request();
        vm.prank(admin);
        arena.startEvaluation(id);
        vm.prank(owner);
        arena.submitEvidence(id, keccak256("ev"));
        assertEq(arena.getEvaluation(id).submittedAt, T0);
        vm.prank(admin);
        vm.expectRevert(AgonArena.InvalidState.selector);
        arena.revokeEvaluation(id, keccak256("r"));
        vm.prank(admin);
        vm.expectRevert(AgonArena.InvalidScore.selector);
        arena.scoreEvaluation(id, 50, bytes32(0));
        vm.prank(admin);
        arena.scoreEvaluation(id, 49, keccak256("resp"));
        assertEq(uint8(arena.getEvaluation(id).state), uint8(AgonArena.State.Rejected));
        assertEq(arena.getEvaluation(id).scoredAt, T0);
        vm.prank(admin);
        vm.expectRevert(AgonArena.ZeroHash.selector);
        arena.revokeEvaluation(id, bytes32(0));
        vm.prank(admin);
        arena.revokeEvaluation(id, keccak256("r"));
        assertEq(uint8(arena.getEvaluation(id).state), uint8(AgonArena.State.Revoked));
    }

    function test_score_of_fifty_passes() public {
        uint256 id = _request();
        vm.prank(admin);
        arena.startEvaluation(id);
        vm.prank(owner);
        arena.submitEvidence(id, keccak256("ev"));
        vm.prank(admin);
        arena.scoreEvaluation(id, 50, keccak256("resp"));
        assertEq(uint8(arena.getEvaluation(id).state), uint8(AgonArena.State.Verified));
    }

    function test_missing_evaluation_is_refused() public {
        vm.expectRevert(AgonArena.EvaluationMissing.selector);
        arena.getEvaluation(1);
        vm.expectRevert(AgonArena.EvaluationMissing.selector);
        arena.expireEvaluation(1);
    }

    function test_pause_blocks_the_lifecycle() public {
        vm.prank(admin);
        arena.pause();
        vm.prank(owner);
        vm.expectRevert();
        arena.requestEvaluation(keccak256("r"), listingId, keccak256("c"), keccak256("e"), keccak256("t"), EXP);
        vm.prank(admin);
        arena.unpause();
        _request();
    }
}
