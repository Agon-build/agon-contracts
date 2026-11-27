// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonJobEscrowV2 } from "../src/AgonJobEscrowV2.sol";
import { BlocklistUSDC } from "./mocks/BlocklistUSDC.sol";

contract PayoutsIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @notice A blocklisted address on Arc makes USDC transfers to it revert. These tests pin
///         that no single blocked party can freeze a job (owner decision D3, KNOWN_ISSUES PRE-02),
///         and the provider's early release of a rejected job's refund (owner decision D4).
///         Runs against the V2 registry the escrow is deployed with.
contract AgonJobEscrowV2PayoutsTest is Test {
    PayoutsIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonJobEscrowV2 internal escrow;
    BlocklistUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal buyer = makeAddr("buyer");
    address internal provider = makeAddr("provider");
    address internal resolver = makeAddr("resolver");
    address internal treasury = makeAddr("treasury");
    uint256 internal constant AMOUNT = 100e6;
    uint256 internal constant FEE = 5e6; // 5% of AMOUNT
    uint64 internal constant REVIEW_HOURS = 35;
    bytes32 internal constant DELIVERABLE = keccak256("deliverable");
    bytes32 internal constant REASON = keccak256("reason");
    uint256 internal listingId;
    uint256 internal nextRef = 1;

    function setUp() public {
        identity = new PayoutsIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        usdc = new BlocklistUSDC();
        escrow = new AgonJobEscrowV2(admin, address(usdc), address(services), resolver, treasury, REVIEW_HOURS, 500);

        identity.mint(provider, 42);
        vm.startPrank(provider);
        profiles.bindProfile(42, "ipfs://profile");
        listingId = services.publish(
            42, keccak256("svc"), keccak256("manifest"), "ipfs://m", 1, AgonServiceRegistryV2.PaymentRail.Escrow
        );
        vm.stopPrank();
        vm.prank(admin);
        services.setVerificationForVersion(listingId, 1, keccak256("manifest"), AgonServiceRegistryV2.Verification.Verified);

        usdc.mint(buyer, 1000e6);
        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _create() internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = escrow.createJob(bytes32(nextRef++), listingId, keccak256("terms"), AMOUNT, 0);
    }

    function _submitted() internal returns (uint256 jobId) {
        jobId = _create();
        vm.startPrank(provider);
        escrow.acceptJob(jobId);
        escrow.submitJob(jobId, DELIVERABLE);
        vm.stopPrank();
    }

    function _rejected() internal returns (uint256 jobId) {
        jobId = _submitted();
        vm.prank(buyer);
        escrow.rejectSubmission(jobId, REASON);
    }

    function test_blocked_provider_still_settles() public {
        uint256 jobId = _submitted();
        usdc.setBlocked(provider, true);
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);

        AgonJobEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(AgonJobEscrowV2.Status.Complete));
        assertEq(uint8(job.settlement), uint8(AgonJobEscrowV2.Settlement.ProviderPaid));
        assertEq(escrow.credits(provider), AMOUNT);
        assertEq(escrow.totalCredits(), AMOUNT);
        assertEq(usdc.balanceOf(treasury), FEE);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
    }

    function test_blocked_provider_still_settles_on_autoAccept() public {
        uint256 jobId = _submitted();
        usdc.setBlocked(provider, true);
        vm.warp(block.timestamp + uint256(REVIEW_HOURS) * 1 hours + 1);
        escrow.autoAccept(jobId);
        assertEq(escrow.credits(provider), AMOUNT);
        assertEq(uint8(escrow.getJob(jobId).status), uint8(AgonJobEscrowV2.Status.Complete));
    }

    function test_blocked_treasury_still_settles() public {
        uint256 jobId = _submitted();
        usdc.setBlocked(treasury, true);
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);
        assertEq(usdc.balanceOf(provider), AMOUNT);
        assertEq(escrow.credits(treasury), FEE);
        assertEq(uint8(escrow.getJob(jobId).status), uint8(AgonJobEscrowV2.Status.Complete));
    }

    function test_blocked_buyer_refund_is_credited() public {
        uint256 jobId = _create();
        usdc.setBlocked(buyer, true);
        vm.warp(block.timestamp + uint256(REVIEW_HOURS) * 1 hours + 1);
        // On Arc a blocklisted address cannot send transactions, so someone else must be able to end the job.
        vm.prank(makeAddr("stranger"));
        escrow.failJob(jobId);
        assertEq(escrow.credits(buyer), AMOUNT + FEE);
        assertEq(uint8(escrow.getJob(jobId).settlement), uint8(AgonJobEscrowV2.Settlement.BuyerRefunded));
    }

    function test_anyone_can_fail_after_the_window_and_only_the_buyer_is_paid() public {
        uint256 jobId = _create();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(AgonJobEscrowV2.AcceptanceWindowOpen.selector);
        escrow.failJob(jobId);
        uint256 before = usdc.balanceOf(buyer);
        vm.warp(block.timestamp + uint256(REVIEW_HOURS) * 1 hours + 1);
        vm.prank(stranger);
        escrow.failJob(jobId);
        assertEq(usdc.balanceOf(buyer), before + AMOUNT + FEE);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_anyone_can_claim_the_rejection_refund_after_the_window() public {
        uint256 jobId = _rejected();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(AgonJobEscrowV2.RejectionWindowOpen.selector);
        escrow.claimRefundAfterRejection(jobId);
        uint256 before = usdc.balanceOf(buyer);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(stranger);
        escrow.claimRefundAfterRejection(jobId);
        assertEq(usdc.balanceOf(buyer), before + AMOUNT + FEE);
    }

    function test_withdrawCredit_pays_once() public {
        uint256 jobId = _submitted();
        usdc.setBlocked(provider, true);
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);
        usdc.setBlocked(provider, false);

        vm.prank(provider);
        escrow.withdrawCredit();
        assertEq(usdc.balanceOf(provider), AMOUNT);
        assertEq(escrow.credits(provider), 0);
        assertEq(escrow.totalCredits(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.NoCredit.selector);
        escrow.withdrawCredit();
    }

    function test_withdrawCredit_reverts_while_still_blocked_and_keeps_credit() public {
        uint256 jobId = _submitted();
        usdc.setBlocked(provider, true);
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);

        vm.prank(provider);
        vm.expectRevert();
        escrow.withdrawCredit();
        assertEq(escrow.credits(provider), AMOUNT);
        assertEq(escrow.totalCredits(), AMOUNT);
    }

    function test_credit_is_only_withdrawn_by_its_owner() public {
        uint256 jobId = _submitted();
        usdc.setBlocked(provider, true);
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);

        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.NoCredit.selector);
        escrow.withdrawCredit();
        assertEq(escrow.credits(provider), AMOUNT);
    }

    function test_acceptRejection_refunds_at_once_and_only_by_provider() public {
        uint256 jobId = _rejected();
        uint256 before = usdc.balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert(AgonJobEscrowV2.NotProvider.selector);
        escrow.acceptRejection(jobId);
        vm.prank(resolver);
        vm.expectRevert(AgonJobEscrowV2.NotProvider.selector);
        escrow.acceptRejection(jobId);

        vm.prank(provider);
        escrow.acceptRejection(jobId);
        assertEq(usdc.balanceOf(buyer), before + AMOUNT + FEE);
        AgonJobEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.status), uint8(AgonJobEscrowV2.Status.Failed));
        assertEq(uint8(job.settlement), uint8(AgonJobEscrowV2.Settlement.BuyerRefunded));
    }

    function test_acceptRejection_only_from_Rejected() public {
        uint256 jobId = _submitted();
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.acceptRejection(jobId);

        uint256 disputed = _rejected();
        vm.prank(buyer);
        escrow.openDispute(disputed, REASON);
        vm.prank(provider);
        vm.expectRevert(AgonJobEscrowV2.InvalidStatus.selector);
        escrow.acceptRejection(disputed);
    }

    function test_acceptRejection_works_while_paused() public {
        uint256 jobId = _rejected();
        vm.prank(admin);
        escrow.pause();
        vm.prank(provider);
        escrow.acceptRejection(jobId);
        assertEq(uint8(escrow.getJob(jobId).status), uint8(AgonJobEscrowV2.Status.Failed));
    }
}
