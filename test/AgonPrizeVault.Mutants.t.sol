// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { AgonPrizeVault } from "../src/AgonPrizeVault.sol";
import { ReentrantUSDC } from "./mocks/ReentrantUSDC.sol";

/// @notice Tests added after mutation testing (2026-11-26) showed these behaviours were not
///         checked: pause on publish and claim, the reentrancy guards on claim and
///         withdrawCredit, four events, zero fees and zero refunds touching nobody, and the
///         claim deadline of a pool with no root.
contract AgonPrizeVaultMutantsTest is Test {
    AgonPrizeVault internal vault;
    ReentrantUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal winner = makeAddr("winner");
    bytes32 internal constant POOL = keccak256("pool");
    uint256 internal constant PRINCIPAL = 100e6;
    uint256 internal constant PRIZE = 60e6;

    function setUp() public {
        usdc = new ReentrantUSDC();
        vault = new AgonPrizeVault(admin, address(usdc), treasury);
        usdc.mint(admin, 1000e6);
        vm.startPrank(admin);
        usdc.approve(address(vault), type(uint256).max);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, admin, PRINCIPAL, 0);
        vm.stopPrank();
    }

    function _leaf(uint256 amount) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(uint256(0), winner, amount))));
    }

    /// @dev A one-leaf tree: the root is the leaf and the proof is empty.
    function _publish(uint256 amount) internal {
        vm.prank(admin);
        vault.publishPayoutRoot(POOL, _leaf(amount), amount, uint64(block.timestamp + 1 days));
    }

    function _creditWinner() internal {
        _publish(PRIZE);
        usdc.setBlocked(winner, true);
        vault.claim(POOL, 0, winner, PRIZE, new bytes32[](0));
        usdc.setBlocked(winner, false);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(usdc.reentered(), "the payout did not reach the token");
        assertEq(usdc.reentryResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function _assertNoPayoutCredited(Vm.Log[] memory logs) internal pure {
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != AgonPrizeVault.PayoutCredited.selector, "credited a zero amount");
        }
    }

    // ---- Pause ----

    function test_publishPayoutRoot_refusedWhilePaused() public {
        vm.startPrank(admin);
        vault.pause();
        bytes32 root = _leaf(PRIZE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.publishPayoutRoot(POOL, root, PRIZE, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function test_claim_refusedWhilePaused() public {
        _publish(PRIZE);
        vm.prank(admin);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(POOL, 0, winner, PRIZE, new bytes32[](0));
    }

    // ---- Reentrancy guards ----

    function test_claim_blocksReentry() public {
        _publish(PRIZE);
        bytes32[] memory proof = new bytes32[](0);
        usdc.arm(address(vault), address(vault), abi.encodeCall(vault.claim, (POOL, 0, winner, PRIZE, proof)));
        vault.claim(POOL, 0, winner, PRIZE, proof);
        _assertReentryBlocked();
        assertEq(usdc.balanceOf(winner), PRIZE);
    }

    function test_withdrawCredit_blocksReentry() public {
        _creditWinner();
        usdc.arm(address(vault), address(vault), abi.encodeCall(vault.withdrawCredit, ()));
        vm.prank(winner);
        vault.withdrawCredit();
        _assertReentryBlocked();
        assertEq(usdc.balanceOf(winner), PRIZE);
    }

    // ---- Events ----

    function test_claim_emitsPrizeClaimed() public {
        _publish(PRIZE);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgonPrizeVault.PrizeClaimed(POOL, 0, winner, PRIZE);
        vault.claim(POOL, 0, winner, PRIZE, new bytes32[](0));
    }

    function test_blockedClaim_emitsPayoutCredited() public {
        _publish(PRIZE);
        usdc.setBlocked(winner, true);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AgonPrizeVault.PayoutCredited(winner, PRIZE);
        vault.claim(POOL, 0, winner, PRIZE, new bytes32[](0));
    }

    function test_withdrawCredit_emitsCreditWithdrawn() public {
        _creditWinner();
        vm.expectEmit(true, false, false, true, address(vault));
        emit AgonPrizeVault.CreditWithdrawn(winner, PRIZE);
        vm.prank(winner);
        vault.withdrawCredit();
    }

    function test_setTreasury_emitsTreasuryUpdated() public {
        address next = makeAddr("next treasury");
        vm.expectEmit(true, true, false, false, address(vault));
        emit AgonPrizeVault.TreasuryUpdated(treasury, next);
        vm.prank(admin);
        vault.setTreasury(next);
        assertEq(vault.treasury(), next);
    }

    // ---- Zero amounts touch nobody ----

    function test_zeroFeePool_doesNotPayTheTreasury() public {
        usdc.setBlocked(treasury, true);
        vm.prank(admin);
        vault.createPool(keccak256("pool 2"), AgonPrizeVault.PoolKind.Arena, 2, admin, PRINCIPAL, 0);
        assertEq(vault.getPool(keccak256("pool 2")).fee, 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_fullyClaimedPool_refundSendsNothing() public {
        _publish(PRINCIPAL);
        vault.claim(POOL, 0, winner, PRINCIPAL, new bytes32[](0));
        usdc.setBlocked(admin, true);
        vm.recordLogs();
        vault.refundRemaining(POOL);
        _assertNoPayoutCredited(vm.getRecordedLogs());
        assertEq(vault.credits(admin), 0);
        assertEq(uint8(vault.getPool(POOL).state), uint8(AgonPrizeVault.State.Closed));
    }

    // ---- Claim deadline before a root ----

    function test_effectiveClaimDeadline_isZeroBeforeTheRoot_evenAfterAPause() public {
        vm.prank(admin);
        vault.pause();
        vm.warp(block.timestamp + 100);
        vm.prank(admin);
        vault.unpause();
        assertEq(vault.effectiveClaimDeadline(POOL), 0);
    }
}
