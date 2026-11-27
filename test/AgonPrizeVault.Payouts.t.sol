// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { AgonPrizeVault } from "../src/AgonPrizeVault.sol";
import { BlocklistUSDC } from "./mocks/BlocklistUSDC.sol";

/// @notice A blocklisted beneficiary or sponsor must not freeze a pool (owner decision D3,
///         KNOWN_ISSUES PRE-02). A failed payout is credited and the pool still moves on.
contract AgonPrizeVaultPayoutsTest is Test {
    AgonPrizeVault internal vault;
    BlocklistUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal winner = makeAddr("winner");
    bytes32 internal constant POOL = keccak256("pool");
    uint256 internal constant PRINCIPAL = 100e6;
    uint256 internal constant PRIZE = 60e6;

    function setUp() public {
        usdc = new BlocklistUSDC();
        vault = new AgonPrizeVault(admin, address(usdc), treasury);
        usdc.mint(admin, 1000e6);
        vm.startPrank(admin);
        usdc.approve(address(vault), type(uint256).max);
        vault.createPool(POOL, AgonPrizeVault.PoolKind.Arena, 1, admin, PRINCIPAL, 0);
        vm.stopPrank();
    }

    /// @dev A one-leaf tree: the root is the leaf and the proof is empty.
    function _publishOneWinner() internal returns (bytes32[] memory proof) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(0), winner, PRIZE))));
        vm.prank(admin);
        vault.publishPayoutRoot(POOL, leaf, PRIZE, uint64(block.timestamp + 1 days));
        proof = new bytes32[](0);
    }

    function test_blocked_beneficiary_claim_is_credited() public {
        bytes32[] memory proof = _publishOneWinner();
        usdc.setBlocked(winner, true);
        vault.claim(POOL, 0, winner, PRIZE, proof);
        assertTrue(vault.isClaimed(POOL, 0));
        assertEq(vault.credits(winner), PRIZE);
        assertEq(vault.getPool(POOL).claimedTotal, PRIZE);

        vm.expectRevert(AgonPrizeVault.AlreadyClaimed.selector);
        vault.claim(POOL, 0, winner, PRIZE, proof);
    }

    function test_blocked_sponsor_refund_is_credited() public {
        _publishOneWinner();
        usdc.setBlocked(admin, true);
        vm.warp(block.timestamp + 1 days + 1);
        vault.refundRemaining(POOL);
        assertEq(uint8(vault.getPool(POOL).state), uint8(AgonPrizeVault.State.Closed));
        assertEq(vault.credits(admin), PRINCIPAL);
    }

    function test_blocked_sponsor_unpublished_refund_is_credited() public {
        usdc.setBlocked(admin, true);
        vm.warp(block.timestamp + vault.ROOT_PUBLISH_WINDOW() + 1);
        vault.refundUnpublished(POOL);
        assertEq(vault.credits(admin), PRINCIPAL);
    }

    function test_withdrawCredit_pays_once_after_unblock() public {
        bytes32[] memory proof = _publishOneWinner();
        usdc.setBlocked(winner, true);
        vault.claim(POOL, 0, winner, PRIZE, proof);

        vm.prank(winner);
        vm.expectRevert();
        vault.withdrawCredit();
        assertEq(vault.credits(winner), PRIZE);

        usdc.setBlocked(winner, false);
        vm.prank(winner);
        vault.withdrawCredit();
        assertEq(usdc.balanceOf(winner), PRIZE);
        assertEq(vault.credits(winner), 0);
        assertEq(vault.totalCredits(), 0);

        vm.prank(winner);
        vm.expectRevert(AgonPrizeVault.NoCredit.selector);
        vault.withdrawCredit();
    }
}
