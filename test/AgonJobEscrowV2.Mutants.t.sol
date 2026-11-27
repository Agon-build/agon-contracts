// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonJobEscrowV2 } from "../src/AgonJobEscrowV2.sol";
import { ReentrantUSDC } from "./mocks/ReentrantUSDC.sol";

contract MutantsIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }
}

/// @notice Tests added after mutation testing (2026-11-26) showed these behaviours were not
///         checked: the admin gate on cancelling a fee change, clearing the pending fee, the
///         reentrancy guards on every payout path, three events, and that a job with no fee
///         sends nothing to the treasury.
contract AgonJobEscrowV2MutantsTest is Test {
    MutantsIdentity internal identity;
    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonJobEscrowV2 internal escrow;
    ReentrantUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal buyer = makeAddr("buyer");
    address internal provider = makeAddr("provider");
    address internal resolver = makeAddr("resolver");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant AMOUNT = 100e6;
    uint64 internal constant REVIEW_HOURS = 35;
    bytes32 internal constant REASON = keccak256("reason");
    uint256 internal listingId;
    uint256 internal nextRef = 1;

    function setUp() public {
        identity = new MutantsIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        usdc = new ReentrantUSDC();
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

    function _create(uint256 amount) internal returns (uint256 jobId) {
        vm.prank(buyer);
        jobId = escrow.createJob(bytes32(nextRef++), listingId, keccak256("terms"), amount, 0);
    }

    function _submitted(uint256 amount) internal returns (uint256 jobId) {
        jobId = _create(amount);
        vm.startPrank(provider);
        escrow.acceptJob(jobId);
        escrow.submitJob(jobId, keccak256("deliverable"));
        vm.stopPrank();
    }

    function _disputed() internal returns (uint256 jobId) {
        jobId = _submitted(AMOUNT);
        vm.startPrank(buyer);
        escrow.rejectSubmission(jobId, REASON);
        escrow.openDispute(jobId, REASON);
        vm.stopPrank();
    }

    function _creditProvider() internal {
        uint256 jobId = _submitted(AMOUNT);
        usdc.setBlocked(provider, true);
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);
        usdc.setBlocked(provider, false);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(usdc.reentered(), "the payout did not reach the token");
        assertEq(usdc.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    // ---- Fee schedule ----

    function test_cancelProtocolFeeChange_onlyAdmin() public {
        vm.prank(admin);
        escrow.scheduleProtocolFeeChange(300);
        bytes32 role = escrow.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        escrow.cancelProtocolFeeChange();
        assertEq(escrow.pendingProtocolFeeBps(), 300);
    }

    function test_applyProtocolFeeChange_clearsThePendingChange() public {
        vm.prank(admin);
        escrow.scheduleProtocolFeeChange(300);
        vm.warp(block.timestamp + escrow.PROTOCOL_FEE_CHANGE_DELAY());
        escrow.applyProtocolFeeChange();
        assertEq(escrow.protocolFeeBps(), 300);
        assertEq(escrow.pendingProtocolFeeBps(), 0);
        assertEq(escrow.pendingProtocolFeeEffectiveAt(), 0);
    }

    // ---- Reentrancy guards on payout paths ----

    function test_acceptSubmission_blocksReentry() public {
        uint256 jobId = _submitted(AMOUNT);
        usdc.arm(address(escrow), address(escrow), abi.encodeCall(escrow.acceptSubmission, (jobId)));
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);
        _assertReentryBlocked();
        assertEq(usdc.balanceOf(provider), AMOUNT);
    }

    function test_resolveDispute_blocksReentry() public {
        uint256 jobId = _disputed();
        usdc.arm(address(escrow), address(escrow), abi.encodeCall(escrow.resolveDispute, (jobId, true)));
        vm.prank(resolver);
        escrow.resolveDispute(jobId, true);
        _assertReentryBlocked();
        assertEq(usdc.balanceOf(provider), AMOUNT);
    }

    function test_withdrawCredit_blocksReentry() public {
        _creditProvider();
        usdc.arm(address(escrow), address(escrow), abi.encodeCall(escrow.withdrawCredit, ()));
        vm.prank(provider);
        escrow.withdrawCredit();
        _assertReentryBlocked();
        assertEq(usdc.balanceOf(provider), AMOUNT);
        assertEq(escrow.credits(provider), 0);
    }

    // ---- Events ----

    function test_blockedPayout_emitsPayoutCredited() public {
        uint256 jobId = _submitted(AMOUNT);
        usdc.setBlocked(provider, true);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit AgonJobEscrowV2.PayoutCredited(provider, AMOUNT);
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);
    }

    function test_withdrawCredit_emitsCreditWithdrawn() public {
        _creditProvider();
        vm.expectEmit(true, false, false, true, address(escrow));
        emit AgonJobEscrowV2.CreditWithdrawn(provider, AMOUNT);
        vm.prank(provider);
        escrow.withdrawCredit();
    }

    function test_acceptRejection_emitsRejectionAccepted() public {
        uint256 jobId = _submitted(AMOUNT);
        vm.prank(buyer);
        escrow.rejectSubmission(jobId, REASON);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit AgonJobEscrowV2.RejectionAccepted(jobId, provider);
        vm.prank(provider);
        escrow.acceptRejection(jobId);
    }

    // ---- A job with no fee ----

    function test_zeroFeeJob_sendsNothingToTheTreasury() public {
        uint256 jobId = _submitted(1); // 1 unit at 5% rounds the fee down to 0
        assertEq(escrow.getJob(jobId).fee, 0);
        usdc.setBlocked(treasury, true);
        vm.recordLogs();
        vm.prank(buyer);
        escrow.acceptSubmission(jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != AgonJobEscrowV2.PayoutCredited.selector, "credited the treasury for a zero fee");
        }
        assertEq(escrow.credits(treasury), 0);
        assertEq(usdc.balanceOf(provider), 1);
    }
}
