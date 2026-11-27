// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonJobEscrowV2 } from "../src/AgonJobEscrowV2.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";

contract EscrowFuzzIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @notice Fuzz tests for AgonJobEscrowV2: fee arithmetic and snapshot, every window boundary,
///         pause extension, review hour bounds, party checks and roles.
/// @dev Times are absolute (T0 and job fields), never `block.timestamp` read after a warp, so the
///      tests also hold under the coverage build.
contract AgonJobEscrowV2FuzzTest is Test {
    EscrowFuzzIdentity internal identity;
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
    uint64 internal constant DEFAULT_HOURS = 35;
    uint256 internal constant MAX_AMOUNT = 1e15; // one billion USDC at 6 decimals
    bytes32 internal constant TERMS = keccak256("terms");
    bytes32 internal constant DELIVERABLE = keccak256("deliverable");
    bytes32 internal constant REASON = keccak256("reason");
    uint256 internal listingId;
    uint256 internal nextRef = 1;

    function setUp() public {
        vm.warp(T0);
        identity = new EscrowFuzzIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        usdc = new MockUSDC();
        escrow = new AgonJobEscrowV2(admin, address(usdc), address(services), resolver, treasury, DEFAULT_HOURS, 500);

        identity.mint(provider, 42);
        vm.startPrank(provider);
        profiles.bindProfile(42, "ipfs://profile");
        listingId = services.publish(
            42, keccak256("svc"), keccak256("manifest"), "ipfs://m", 1, AgonServiceRegistryV2.PaymentRail.Escrow
        );
        vm.stopPrank();
        vm.prank(admin);
        services.setVerificationForVersion(listingId, 1, keccak256("manifest"), AgonServiceRegistryV2.Verification.Verified);

        usdc.mint(buyer, 4 * MAX_AMOUNT);
        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _create(uint256 amount, uint64 reviewHours) internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = escrow.createJob(bytes32(nextRef++), listingId, TERMS, amount, reviewHours);
    }

    function _setFee(uint16 feeBps) internal {
        if (feeBps == escrow.protocolFeeBps()) return;
        uint256 at = T0;
        vm.prank(admin);
        escrow.scheduleProtocolFeeChange(feeBps);
        vm.warp(at + escrow.PROTOCOL_FEE_CHANGE_DELAY());
        escrow.applyProtocolFeeChange();
        vm.warp(at);
    }

    function _submitted(uint256 amount, uint64 reviewHours) internal returns (uint256 jobId) {
        jobId = _create(amount, reviewHours);
        vm.startPrank(provider);
        escrow.acceptJob(jobId);
        escrow.submitJob(jobId, DELIVERABLE);
        vm.stopPrank();
    }

    function _rejected(uint256 amount) internal returns (uint256 jobId) {
        jobId = _submitted(amount, DEFAULT_HOURS);
        vm.prank(buyer);
        escrow.rejectSubmission(jobId, REASON);
    }

    function _assertSettledOnce(uint256 jobId, AgonJobEscrowV2.Settlement settlement) internal view {
        AgonJobEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.settlement), uint8(settlement));
        assertEq(escrow.escrowedAmount(jobId), 0);
    }

    // ---------------------------------------------------------------- fees

    /// INV-ESC-04: fee = amount * feeBps / 10,000, fixed at creation; INV-ESC-03: payout split.
    function testFuzz_feeIsComputedAndSnapshotted(uint256 amount, uint16 feeBps, uint16 laterFeeBps) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        feeBps = uint16(bound(feeBps, 0, escrow.MAX_PROTOCOL_FEE_BPS()));
        laterFeeBps = uint16(bound(laterFeeBps, 0, escrow.MAX_PROTOCOL_FEE_BPS()));
        _setFee(feeBps);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 jobId = _create(amount, 0);
        uint256 fee = (amount * feeBps) / 10_000;
        AgonJobEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.fee, fee);
        assertEq(job.feeBps, feeBps);
        assertEq(buyerBefore - usdc.balanceOf(buyer), amount + fee);
        assertEq(usdc.balanceOf(address(escrow)), amount + fee);

        _setFee(laterFeeBps);
        assertEq(escrow.getJob(jobId).fee, fee);

        vm.startPrank(provider);
        escrow.acceptJob(jobId);
        escrow.submitJob(jobId, DELIVERABLE);
        vm.stopPrank();
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);

        assertEq(usdc.balanceOf(provider), amount);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        _assertSettledOnce(jobId, AgonJobEscrowV2.Settlement.ProviderPaid);
    }

    function testFuzz_feeAboveCapIsRefused(uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, escrow.MAX_PROTOCOL_FEE_BPS() + 1, type(uint16).max));
        vm.prank(admin);
        vm.expectRevert(AgonJobEscrowV2.FeeAboveMaximum.selector);
        escrow.scheduleProtocolFeeChange(feeBps);
    }

    function testFuzz_feeChangeWaitsForItsDelay(uint16 feeBps, uint256 early) public {
        feeBps = uint16(bound(feeBps, 0, escrow.MAX_PROTOCOL_FEE_BPS()));
        vm.assume(feeBps != escrow.protocolFeeBps());
        early = bound(early, 0, escrow.PROTOCOL_FEE_CHANGE_DELAY() - 1);
        vm.prank(admin);
        escrow.scheduleProtocolFeeChange(feeBps);
        vm.warp(T0 + early);
        vm.expectRevert(AgonJobEscrowV2.FeeChangeTimelocked.selector);
        escrow.applyProtocolFeeChange();
        assertEq(escrow.protocolFeeBps(), 500);
    }

    // ---------------------------------------------------------------- review hours

    function testFuzz_reviewHoursBounds(uint64 reviewHours) public {
        if (reviewHours > escrow.MAX_REVIEW_HOURS()) {
            vm.prank(buyer);
            vm.expectRevert(AgonJobEscrowV2.InvalidReviewHours.selector);
            escrow.createJob(bytes32(nextRef++), listingId, TERMS, 1e6, reviewHours);
            return;
        }
        uint256 jobId = _create(1e6, reviewHours);
        uint64 expected = reviewHours == 0 ? DEFAULT_HOURS : reviewHours;
        AgonJobEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.reviewHours, expected);
        assertEq(job.acceptanceDeadline, T0 + uint256(expected) * 1 hours);
    }

    // ---------------------------------------------------------------- windows

    function testFuzz_acceptanceWindowBoundary(uint64 reviewHours, uint256 elapsed) public {
        reviewHours = uint64(bound(reviewHours, 1, escrow.MAX_REVIEW_HOURS()));
        elapsed = bound(elapsed, 0, uint256(reviewHours) * 1 hours * 2);
        uint256 jobId = _create(10e6, reviewHours);
        uint256 deadline = T0 + uint256(reviewHours) * 1 hours;
        vm.warp(T0 + elapsed);

        if (T0 + elapsed <= deadline) {
            vm.prank(buyer);
            vm.expectRevert(AgonJobEscrowV2.AcceptanceWindowOpen.selector);
            escrow.failJob(jobId);
            vm.prank(provider);
            escrow.acceptJob(jobId);
            assertEq(uint8(escrow.getJob(jobId).status), uint8(AgonJobEscrowV2.Status.Accepted));
        } else {
            vm.prank(provider);
            vm.expectRevert(AgonJobEscrowV2.AcceptanceWindowClosed.selector);
            escrow.acceptJob(jobId);
            uint256 before = usdc.balanceOf(buyer);
            vm.prank(makeAddr("anyone"));
            escrow.failJob(jobId);
            assertEq(usdc.balanceOf(buyer) - before, 10e6 + escrow.getJob(jobId).fee);
            _assertSettledOnce(jobId, AgonJobEscrowV2.Settlement.BuyerRefunded);
        }
    }

    function testFuzz_reviewWindowBoundary(uint64 reviewHours, uint256 elapsed) public {
        reviewHours = uint64(bound(reviewHours, 1, escrow.MAX_REVIEW_HOURS()));
        elapsed = bound(elapsed, 0, uint256(reviewHours) * 1 hours * 2);
        uint256 jobId = _submitted(10e6, reviewHours);
        uint256 reviewDeadline = escrow.getJob(jobId).reviewDeadline;
        assertEq(reviewDeadline, T0 + uint256(reviewHours) * 1 hours);
        vm.warp(T0 + elapsed);

        if (T0 + elapsed <= reviewDeadline) {
            vm.expectRevert(AgonJobEscrowV2.ReviewWindowOpen.selector);
            escrow.autoAccept(jobId);
            vm.prank(buyer);
            escrow.rejectSubmission(jobId, REASON);
            assertEq(uint8(escrow.getJob(jobId).status), uint8(AgonJobEscrowV2.Status.Rejected));
        } else {
            vm.prank(buyer);
            vm.expectRevert(AgonJobEscrowV2.ReviewWindowClosed.selector);
            escrow.rejectSubmission(jobId, REASON);
            vm.prank(makeAddr("anyone"));
            escrow.autoAccept(jobId);
            assertEq(usdc.balanceOf(provider), 10e6);
            _assertSettledOnce(jobId, AgonJobEscrowV2.Settlement.ProviderPaid);
        }
    }

    function testFuzz_rejectionWindowBoundary(uint256 elapsed, address caller) public {
        vm.assume(caller != address(0));
        elapsed = bound(elapsed, 0, 2 * uint256(escrow.REJECTION_WINDOW()));
        uint256 jobId = _rejected(10e6);
        vm.warp(T0 + elapsed);

        if (elapsed <= escrow.REJECTION_WINDOW()) {
            vm.prank(caller);
            vm.expectRevert(AgonJobEscrowV2.RejectionWindowOpen.selector);
            escrow.claimRefundAfterRejection(jobId);
            vm.prank(provider);
            escrow.openDispute(jobId, REASON);
            assertEq(uint8(escrow.getJob(jobId).status), uint8(AgonJobEscrowV2.Status.Disputed));
        } else {
            vm.prank(provider);
            vm.expectRevert(AgonJobEscrowV2.RejectionWindowClosed.selector);
            escrow.openDispute(jobId, REASON);
            uint256 before = usdc.balanceOf(buyer);
            vm.prank(caller);
            escrow.claimRefundAfterRejection(jobId);
            assertEq(usdc.balanceOf(buyer) - before, 10e6 + escrow.getJob(jobId).fee);
            _assertSettledOnce(jobId, AgonJobEscrowV2.Settlement.BuyerRefunded);
        }
    }

    function testFuzz_resolverWindowBoundary(uint256 elapsed, bool payProvider) public {
        elapsed = bound(elapsed, 0, 2 * uint256(escrow.RESOLVER_WINDOW()));
        uint256 jobId = _rejected(10e6);
        vm.prank(provider);
        escrow.openDispute(jobId, REASON);
        vm.warp(T0 + elapsed);

        if (elapsed <= escrow.RESOLVER_WINDOW()) {
            vm.prank(buyer);
            vm.expectRevert(AgonJobEscrowV2.ResolverWindowOpen.selector);
            escrow.exitStaleDispute(jobId);
            vm.prank(resolver);
            escrow.resolveDispute(jobId, payProvider);
            _assertSettledOnce(
                jobId,
                payProvider ? AgonJobEscrowV2.Settlement.ProviderPaid : AgonJobEscrowV2.Settlement.BuyerRefunded
            );
        } else {
            vm.prank(resolver);
            vm.expectRevert(AgonJobEscrowV2.ResolverWindowClosed.selector);
            escrow.resolveDispute(jobId, payProvider);
            vm.prank(provider);
            escrow.exitStaleDispute(jobId);
            _assertSettledOnce(jobId, AgonJobEscrowV2.Settlement.BuyerRefunded);
        }
    }

    // ---------------------------------------------------------------- pause

    /// INV-ESC-07: paused time never shortens the acceptance window.
    function testFuzz_pauseExtendsAcceptanceWindow(uint256 before, uint256 pauseAt, uint256 pauseFor) public {
        before = bound(before, 0, 30 days);
        pauseAt = bound(pauseAt, 0, uint256(DEFAULT_HOURS) * 1 hours);
        pauseFor = bound(pauseFor, 1, 60 days);

        // A pause that ends before the job exists does not count for it.
        vm.prank(admin);
        escrow.pause();
        vm.warp(T0 + before);
        vm.prank(admin);
        escrow.unpause();
        uint256 created = T0 + before;
        uint256 jobId = _create(10e6, 0);
        uint256 deadline = created + uint256(DEFAULT_HOURS) * 1 hours;
        assertEq(escrow.effectiveAcceptanceDeadline(jobId), deadline);

        vm.warp(created + pauseAt);
        vm.prank(admin);
        escrow.pause();
        vm.warp(created + pauseAt + pauseFor);
        assertEq(escrow.effectiveAcceptanceDeadline(jobId), deadline + pauseFor);
        vm.prank(admin);
        escrow.unpause();
        assertEq(escrow.effectiveAcceptanceDeadline(jobId), deadline + pauseFor);

        vm.warp(deadline + pauseFor);
        vm.prank(provider);
        escrow.acceptJob(jobId);
    }

    // ---------------------------------------------------------------- parties and roles

    /// INV-ESC-06: only the right party moves a job.
    function testFuzz_onlyPartiesAct(address caller) public {
        vm.assume(caller != buyer && caller != provider && caller != resolver);
        uint256 jobId = _create(10e6, 0);

        vm.prank(caller);
        vm.expectRevert(AgonJobEscrowV2.NotProvider.selector);
        escrow.acceptJob(jobId);

        vm.startPrank(provider);
        escrow.acceptJob(jobId);
        escrow.submitJob(jobId, DELIVERABLE);
        vm.stopPrank();

        vm.startPrank(caller);
        vm.expectRevert(AgonJobEscrowV2.NotBuyer.selector);
        escrow.acceptSubmission(jobId);
        vm.expectRevert(AgonJobEscrowV2.NotBuyer.selector);
        escrow.rejectSubmission(jobId, REASON);
        vm.stopPrank();

        vm.prank(buyer);
        escrow.rejectSubmission(jobId, REASON);
        vm.startPrank(caller);
        vm.expectRevert(AgonJobEscrowV2.NotProvider.selector);
        escrow.acceptRejection(jobId);
        vm.expectRevert(AgonJobEscrowV2.NotParty.selector);
        escrow.openDispute(jobId, REASON);
        vm.stopPrank();

        vm.prank(buyer);
        escrow.openDispute(jobId, REASON);
        vm.prank(caller);
        vm.expectRevert(AgonJobEscrowV2.NotDisputeResolver.selector);
        escrow.resolveDispute(jobId, true);
    }

    /// INV-ESC-08: a client reference is used once per buyer, and only for that buyer.
    function testFuzz_clientReferenceUsedOncePerBuyer(bytes32 ref, address otherBuyer) public {
        vm.assume(ref != bytes32(0));
        vm.assume(otherBuyer != address(0) && otherBuyer != buyer && otherBuyer != address(escrow));
        vm.prank(buyer);
        escrow.createJob(ref, listingId, TERMS, 1e6, 0);
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.JobReferenceAlreadyUsed.selector);
        escrow.createJob(ref, listingId, TERMS, 1e6, 0);

        usdc.mint(otherBuyer, 2e6);
        vm.startPrank(otherBuyer);
        usdc.approve(address(escrow), type(uint256).max);
        uint256 jobId = escrow.createJob(ref, listingId, TERMS, 1e6, 0);
        vm.stopPrank();
        assertEq(escrow.jobByReference(otherBuyer, ref), jobId);
    }

    function testFuzz_strangerHoldsNoRole(address stranger, uint16 feeBps) public {
        vm.assume(stranger != admin);
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, escrow.PAUSER_ROLE()
            )
        );
        escrow.pause();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, escrow.DEFAULT_ADMIN_ROLE()
            )
        );
        escrow.scheduleProtocolFeeChange(feeBps);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, escrow.DEFAULT_ADMIN_ROLE()
            )
        );
        escrow.setTreasury(stranger);
        vm.stopPrank();
    }

    /// A handed-over admin keeps every power; the old admin, once renounced, keeps none.
    function testFuzz_adminHandoff(address newAdmin) public {
        vm.assume(newAdmin != address(0) && newAdmin != admin);
        bytes32 adminRole = escrow.DEFAULT_ADMIN_ROLE();
        bytes32 pauserRole = escrow.PAUSER_ROLE();
        vm.startPrank(admin);
        escrow.grantRole(adminRole, newAdmin);
        escrow.grantRole(pauserRole, newAdmin);
        escrow.renounceRole(pauserRole, admin);
        escrow.renounceRole(adminRole, admin);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, pauserRole)
        );
        escrow.pause();

        vm.prank(newAdmin);
        escrow.pause();
        assertTrue(escrow.paused());
    }

    /// A revoked pauser can no longer pause.
    function testFuzz_revokedPauserCannotPause(address pauser) public {
        vm.assume(pauser != address(0) && pauser != admin);
        bytes32 pauserRole = escrow.PAUSER_ROLE();
        vm.prank(admin);
        escrow.grantRole(pauserRole, pauser);
        vm.prank(admin);
        escrow.revokeRole(pauserRole, pauser);
        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, pauserRole)
        );
        escrow.pause();
    }

    // ---------------------------------------------------------------- binding

    /// INV-ESC-05: a job stays bound to its listing version, manifest and provider.
    function testFuzz_jobStaysBoundToItsVersion(bytes32 newManifest) public {
        vm.assume(newManifest != bytes32(0) && newManifest != keccak256("manifest"));
        uint256 jobId = _create(10e6, 0);
        vm.prank(provider);
        services.publishVersion(listingId, newManifest, "ipfs://m2", AgonServiceRegistryV2.PaymentRail.Escrow);

        AgonJobEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(job.listingVersion, 1);
        assertEq(job.manifestHash, keccak256("manifest"));
        assertEq(job.provider, provider);

        // The new version is Unverified, so no new job may be created until it is checked again.
        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.ListingNotEscrowEligible.selector);
        escrow.createJob(bytes32(nextRef++), listingId, TERMS, 1e6, 0);
    }
}
