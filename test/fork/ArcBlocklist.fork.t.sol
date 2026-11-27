// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AgonProfileRegistry } from "../../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../../src/AgonServiceRegistryV2.sol";
import { AgonJobEscrowV2 } from "../../src/AgonJobEscrowV2.sol";
import { AgonPrizeVault } from "../../src/AgonPrizeVault.sol";
import { InvariantIdentity } from "../invariant/EscrowHandler.sol";

/// @notice The credit path against Arc's real USDC and real blocklist, on a fork of Arc Testnet.
/// @dev Runs only when ARC_TESTNET_RPC_URL is set, and must run under Arc Foundry (`arc-forge`):
///      standard Foundry does not model Arc's USDC precompile, so the first check below fails there
///      on purpose rather than passing without testing anything.
///      Run: `ARC_TESTNET_RPC_URL=<rpc> arc-forge test --fork-url <rpc> --match-path 'test/fork/*'`.
///      Facts from the Arc docs (read 2026-11-26): USDC ERC-20 interface at 0x3600..0000 with 6
///      decimals; the seeded blocklisted test address 0x7099..79C8 (mnemonic index 1 of the public
///      test mnemonic) reverts any value transfer to or from it at runtime.
contract ArcBlocklistForkTest is Test {
    IERC20 internal constant USDC = IERC20(0x3600000000000000000000000000000000000000);
    address internal constant BLOCKED = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    AgonProfileRegistry internal profiles;
    AgonServiceRegistryV2 internal services;
    AgonJobEscrowV2 internal escrow;
    AgonPrizeVault internal vault;
    InvariantIdentity internal identity;

    address internal admin = makeAddr("fork-admin");
    address internal buyer = makeAddr("fork-buyer");
    address internal treasury = makeAddr("fork-treasury");
    address internal resolver = makeAddr("fork-resolver");
    uint256 internal listingId;

    function setUp() public {
        string memory rpc = vm.envOr("ARC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Arc Foundry installs Arc's precompiles when the fork comes from `--fork-url`; a fork made
        // inside the test does not get them. Use the command-line fork when there is one.
        if (block.chainid != 5_042_002) vm.createSelectFork(rpc);

        identity = new InvariantIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        escrow = new AgonJobEscrowV2(admin, address(USDC), address(services), resolver, treasury, 24, 500);
        vault = new AgonPrizeVault(admin, address(USDC), treasury);

        // The blocklisted address is the provider: it owns the agent and publishes the listing.
        identity.mint(BLOCKED, 42);
        vm.startPrank(BLOCKED);
        profiles.bindProfile(42, "ipfs://profile");
        listingId = services.publish(
            42, keccak256("svc"), keccak256("manifest"), "ipfs://m", 1, AgonServiceRegistryV2.PaymentRail.Escrow
        );
        vm.stopPrank();
        vm.prank(admin);
        services.setVerificationForVersion(listingId, 1, keccak256("manifest"), AgonServiceRegistryV2.Verification.Verified);

        // On Arc the native balance is the USDC balance: 18 decimals natively, 6 through the ERC-20.
        vm.deal(buyer, 1000 ether);
    }

    /// The fork really applies Arc's rules: native balance shows as USDC, and the seeded address
    /// cannot receive it. If either fails, this is not running under Arc Foundry.
    function test_fork_models_arc_usdc_and_blocklist() public {
        assertEq(block.chainid, 5_042_002);
        assertEq(USDC.balanceOf(buyer), 1000e6);
        // A normal transfer must work, or the blocked one below would revert for the wrong reason.
        vm.prank(buyer);
        assertTrue(USDC.transfer(treasury, 1e6));
        assertEq(USDC.balanceOf(treasury), 1e6);
        vm.prank(buyer);
        vm.expectRevert();
        USDC.transfer(BLOCKED, 1e6);
    }

    /// PRE-02 on Arc itself: a payout to a blocklisted provider is credited, the job still settles,
    /// the treasury is paid, and the blocked address cannot withdraw while blocked.
    function test_blocked_provider_payout_is_credited_on_arc() public {
        vm.startPrank(buyer);
        USDC.approve(address(escrow), type(uint256).max);
        uint256 jobId = escrow.createJob(bytes32(uint256(1)), listingId, keccak256("terms"), 100e6, 0);
        vm.stopPrank();
        vm.startPrank(BLOCKED);
        escrow.acceptJob(jobId);
        escrow.submitJob(jobId, keccak256("deliverable"));
        vm.stopPrank();

        vm.prank(buyer);
        escrow.acceptSubmission(jobId);

        AgonJobEscrowV2.Job memory job = escrow.getJob(jobId);
        assertEq(uint8(job.settlement), uint8(AgonJobEscrowV2.Settlement.ProviderPaid));
        assertEq(escrow.credits(BLOCKED), 100e6);
        assertEq(escrow.totalCredits(), 100e6);
        assertEq(USDC.balanceOf(treasury), 5e6);
        assertEq(USDC.balanceOf(address(escrow)), 100e6);

        vm.prank(BLOCKED);
        vm.expectRevert();
        escrow.withdrawCredit();
        assertEq(escrow.credits(BLOCKED), 100e6);
    }

    /// A prize claimed for a blocklisted winner is credited and the pool keeps working.
    function test_blocked_winner_prize_is_credited_on_arc() public {
        bytes32 operatorRole = vault.POOL_OPERATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(operatorRole, buyer);
        vm.startPrank(buyer);
        USDC.approve(address(vault), type(uint256).max);
        vault.createPool(keccak256("pool"), AgonPrizeVault.PoolKind.Arena, 1, buyer, 100e6, 0);
        bytes32 leafBlocked = keccak256(bytes.concat(keccak256(abi.encode(uint256(0), BLOCKED, uint256(60e6)))));
        bytes32 leafOther = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), treasury, uint256(40e6)))));
        bytes32 root = leafBlocked < leafOther
            ? keccak256(bytes.concat(leafBlocked, leafOther))
            : keccak256(bytes.concat(leafOther, leafBlocked));
        vault.publishPayoutRoot(keccak256("pool"), root, 100e6, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafOther;
        vault.claim(keccak256("pool"), 0, BLOCKED, 60e6, proof);
        proof[0] = leafBlocked;
        vault.claim(keccak256("pool"), 1, treasury, 40e6, proof);

        assertEq(vault.credits(BLOCKED), 60e6);
        assertEq(USDC.balanceOf(treasury), 40e6);
        assertEq(vault.getPool(keccak256("pool")).claimedTotal, 100e6);
    }
}
