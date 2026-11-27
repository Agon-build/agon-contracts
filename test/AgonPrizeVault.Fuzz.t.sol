// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { AgonPrizeVault } from "../src/AgonPrizeVault.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";

/// @notice Fuzz tests for AgonPrizeVault: fee and principal, Merkle claims, the payout cap,
///         window boundaries and pause extension.
/// @dev Times are absolute (T0), never `block.timestamp` read after a warp.
contract AgonPrizeVaultFuzzTest is Test {
    MockUSDC internal usdc;
    AgonPrizeVault internal vault;
    address internal admin = makeAddr("admin");
    address internal sponsor = makeAddr("sponsor");
    address internal treasury = makeAddr("treasury");
    bytes32 internal constant POOL = keccak256("pool");
    uint256 internal constant T0 = 1_000_000;
    uint256 internal constant MAX_PRINCIPAL = 1e15;

    function setUp() public {
        vm.warp(T0);
        usdc = new MockUSDC();
        vault = new AgonPrizeVault(admin, address(usdc), treasury);
        usdc.mint(sponsor, 2 * MAX_PRINCIPAL);
        vm.prank(sponsor);
        usdc.approve(address(vault), type(uint256).max);
        bytes32 operatorRole = vault.POOL_OPERATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(operatorRole, sponsor);
    }

    function _leaf(uint256 index, address beneficiary, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, beneficiary, amount))));
    }

    function _root(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _fund(uint256 principal, uint16 feeBps) internal {
        vm.prank(sponsor);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, sponsor, principal, feeBps);
    }

    /// Fee goes to the treasury at funding, the principal stays in the vault.
    function testFuzz_fundingSplitsFeeAndPrincipal(uint256 principal, uint16 feeBps) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        feeBps = uint16(bound(feeBps, 0, vault.MAX_FEE_BPS()));
        uint256 before = usdc.balanceOf(sponsor);
        _fund(principal, feeBps);
        uint256 fee = (principal * feeBps) / 10_000;
        assertEq(before - usdc.balanceOf(sponsor), principal + fee);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(address(vault)), principal);
        assertEq(vault.getPool(POOL).sponsor, sponsor);
    }

    function testFuzz_feeAboveCapIsRefused(uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, vault.MAX_FEE_BPS() + 1, type(uint16).max));
        vm.prank(sponsor);
        vm.expectRevert(AgonPrizeVault.InvalidFee.selector);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, sponsor, 1e6, feeBps);
    }

    /// INV-VLT-06: the sponsor is the caller; an operator cannot pull another address's approval.
    function testFuzz_sponsorMustBeCaller(address other) public {
        vm.assume(other != sponsor);
        vm.prank(sponsor);
        vm.expectRevert(other == address(0) ? AgonPrizeVault.ZeroAddress.selector : AgonPrizeVault.SponsorMustBeCaller.selector);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, other, 1e6, 0);
    }

    /// INV-VLT-01, INV-VLT-03, INV-VLT-04: claims pay the leaf's beneficiary once, never above the total.
    function testFuzz_claimsPayEachLeafOnce(
        uint256 principal,
        uint256 a,
        uint256 b,
        address alice,
        address bob
    ) public {
        vm.assume(alice != address(0) && bob != address(0) && alice != bob);
        vm.assume(alice != address(vault) && bob != address(vault) && alice != sponsor && bob != sponsor);
        vm.assume(alice != treasury && bob != treasury);
        principal = bound(principal, 2, MAX_PRINCIPAL);
        a = bound(a, 1, principal - 1);
        b = bound(b, 1, principal - a);
        _fund(principal, 0);

        bytes32 leafA = _leaf(0, alice, a);
        bytes32 leafB = _leaf(1, bob, b);
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, _root(leafA, leafB), a + b, uint64(T0 + 7 days));

        // A leaf claimed with the wrong amount or beneficiary does not verify.
        vm.expectRevert(AgonPrizeVault.InvalidProof.selector);
        vault.claim(POOL, 0, alice, a + 1, _proof(leafB));
        vm.expectRevert(AgonPrizeVault.InvalidProof.selector);
        vault.claim(POOL, 0, bob, a, _proof(leafB));

        vault.claim(POOL, 0, alice, a, _proof(leafB));
        vm.expectRevert(AgonPrizeVault.AlreadyClaimed.selector);
        vault.claim(POOL, 0, alice, a, _proof(leafB));
        vault.claim(POOL, 1, bob, b, _proof(leafA));

        AgonPrizeVault.Pool memory pool = vault.getPool(POOL);
        assertEq(pool.claimedTotal, a + b);
        assertLe(pool.claimedTotal, pool.payoutTotal);
        assertLe(pool.payoutTotal, pool.principal);
        assertEq(usdc.balanceOf(alice), a);
        assertEq(usdc.balanceOf(bob), b);

        // Every payout claimed: the leftover goes back to the sponsor at once.
        uint256 sponsorBefore = usdc.balanceOf(sponsor);
        vault.refundRemaining(POOL);
        assertEq(usdc.balanceOf(sponsor) - sponsorBefore, principal - a - b);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function testFuzz_payoutAbovePrincipalIsRefused(uint256 principal, uint256 total) public {
        principal = bound(principal, 1, MAX_PRINCIPAL);
        total = bound(total, principal + 1, type(uint128).max);
        _fund(principal, 0);
        vm.prank(sponsor);
        vm.expectRevert(AgonPrizeVault.PayoutExceedsPrincipal.selector);
        vault.publishPayoutRoot(POOL, keccak256("root"), total, uint64(T0 + 1 days));
    }

    function testFuzz_rootPublishWindowBoundary(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 2 * uint256(vault.ROOT_PUBLISH_WINDOW()));
        _fund(1000e6, 0);
        uint256 deadline = T0 + vault.ROOT_PUBLISH_WINDOW();
        assertEq(vault.rootPublishDeadline(POOL), deadline);
        vm.warp(T0 + elapsed);

        if (T0 + elapsed <= deadline) {
            vm.expectRevert(AgonPrizeVault.RootPublishWindowOpen.selector);
            vault.refundUnpublished(POOL);
            vm.prank(sponsor);
            vault.publishPayoutRoot(POOL, keccak256("root"), 1000e6, uint64(T0 + elapsed + 1));
        } else {
            vm.prank(sponsor);
            vm.expectRevert(AgonPrizeVault.RootPublishWindowClosed.selector);
            vault.publishPayoutRoot(POOL, keccak256("root"), 1000e6, uint64(T0 + elapsed + 1));
            uint256 before = usdc.balanceOf(sponsor);
            vault.refundUnpublished(POOL);
            assertEq(usdc.balanceOf(sponsor) - before, 1000e6);
        }
    }

    function testFuzz_claimWindowBoundary(uint256 window, uint256 elapsed) public {
        window = bound(window, 1, 365 days);
        elapsed = bound(elapsed, 0, 2 * window);
        address alice = makeAddr("alice");
        bytes32 leafA = _leaf(0, alice, 600e6);
        bytes32 leafB = _leaf(1, makeAddr("bob"), 300e6);
        _fund(1000e6, 0);
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, _root(leafA, leafB), 900e6, uint64(T0 + window));
        vm.warp(T0 + elapsed);

        if (elapsed <= window) {
            vm.expectRevert(AgonPrizeVault.RefundWindowOpen.selector);
            vault.refundRemaining(POOL);
            vault.claim(POOL, 0, alice, 600e6, _proof(leafB));
            assertEq(usdc.balanceOf(alice), 600e6);
        } else {
            vm.expectRevert(AgonPrizeVault.ClaimWindowClosed.selector);
            vault.claim(POOL, 0, alice, 600e6, _proof(leafB));
            vault.refundRemaining(POOL);
            assertEq(usdc.balanceOf(address(vault)), 0);
        }
    }

    /// PRE-09: at the claim deadline itself a claim still works, so a refund must wait one more second.
    function test_refundWaitsUntilAfterClaimDeadline() public {
        address alice = makeAddr("alice");
        bytes32 leafA = _leaf(0, alice, 600e6);
        bytes32 leafB = _leaf(1, makeAddr("bob"), 300e6);
        _fund(1000e6, 0);
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, _root(leafA, leafB), 900e6, uint64(T0 + 7 days));

        vm.warp(T0 + 7 days);
        vm.expectRevert(AgonPrizeVault.RefundWindowOpen.selector);
        vault.refundRemaining(POOL);
        vault.claim(POOL, 0, alice, 600e6, _proof(leafB));

        vm.warp(T0 + 7 days + 1);
        vault.refundRemaining(POOL);
        assertEq(usdc.balanceOf(sponsor), 2 * MAX_PRINCIPAL - 600e6);
    }

    /// INV-VLT-05: paused time never shortens the root publish window or the claim window.
    function testFuzz_pauseExtendsBothWindows(uint256 pauseAt, uint256 pauseFor) public {
        pauseAt = bound(pauseAt, 0, 10 days);
        pauseFor = bound(pauseFor, 1, 90 days);
        _fund(1000e6, 0);

        vm.warp(T0 + pauseAt);
        vm.prank(admin);
        vault.pause();
        vm.warp(T0 + pauseAt + pauseFor);
        vm.prank(admin);
        vault.unpause();
        assertEq(vault.rootPublishDeadline(POOL), T0 + vault.ROOT_PUBLISH_WINDOW() + pauseFor);

        uint256 publishedAt = T0 + pauseAt + pauseFor;
        uint64 claimDeadline = uint64(publishedAt + 7 days);
        vm.prank(sponsor);
        vault.publishPayoutRoot(POOL, keccak256("root"), 900e6, claimDeadline);
        assertEq(vault.effectiveClaimDeadline(POOL), claimDeadline);

        vm.warp(publishedAt + 1 days);
        vm.prank(admin);
        vault.pause();
        vm.warp(publishedAt + 1 days + pauseFor);
        vm.prank(admin);
        vault.unpause();
        assertEq(vault.effectiveClaimDeadline(POOL), uint256(claimDeadline) + pauseFor);
    }

    function testFuzz_strangerHoldsNoRole(address stranger) public {
        vm.assume(stranger != admin && stranger != sponsor);
        bytes32 operatorRole = vault.POOL_OPERATOR_ROLE();
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, operatorRole)
        );
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, stranger, 1e6, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        vault.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        vault.setTreasury(stranger);
        vm.stopPrank();
    }
}
