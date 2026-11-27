// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { AgonPrizeVault } from "../../src/AgonPrizeVault.sol";
import { BlocklistUSDC } from "../mocks/BlocklistUSDC.sol";

/// @notice Drives AgonPrizeVault through random sequences: pools funded by two sponsors, two-leaf
///         payout roots for three winners, claims by anyone, both refunds, pauses, time warps,
///         treasury changes and Arc blocklisting. Calls that revert are skipped.
/// @dev Ghost state tracks what every address should have received, so the invariants can check
///      that money only ever reaches a leaf's beneficiary, the sponsor or the treasury.
contract VaultHandler is Test {
    struct PoolGhost {
        address sponsor;
        address[2] beneficiaries;
        uint256[2] amounts;
        bool[2] claimed;
        bytes32 root;
    }

    uint256 public constant MAX_POOLS = 8;

    AgonPrizeVault public vault;
    BlocklistUSDC public usdc;
    address public admin = makeAddr("vault-admin");
    address[2] public sponsors = [makeAddr("vault-sponsor-a"), makeAddr("vault-sponsor-b")];
    address[3] public winners = [makeAddr("vault-winner-a"), makeAddr("vault-winner-b"), makeAddr("vault-winner-c")];
    address[2] public treasuries = [makeAddr("vault-treasury-a"), makeAddr("vault-treasury-b")];
    address public stranger = makeAddr("vault-stranger");
    uint256 public constant SPONSOR_START = 1e18;

    uint256 public time = 1_000_000;
    uint256 internal keyNonce;
    bytes32[] public poolKeys;
    mapping(bytes32 => PoolGhost) internal _ghost;

    /// What each address has gained (or, for sponsors, lost) through the vault, by the rules.
    mapping(address => int256) public expectedDelta;
    /// Set when a leaf is paid twice.
    bool public doubleClaim;
    /// Set when a claim succeeds for a leaf the root does not contain.
    bool public foreignClaim;

    mapping(bytes32 => uint256) public calls;

    constructor() {
        vm.warp(time);
        usdc = new BlocklistUSDC();
        vault = new AgonPrizeVault(admin, address(usdc), treasuries[0]);
        bytes32 operatorRole = vault.POOL_OPERATOR_ROLE();
        for (uint256 i = 0; i < 2; i++) {
            usdc.mint(sponsors[i], SPONSOR_START);
            vm.prank(sponsors[i]);
            usdc.approve(address(vault), type(uint256).max);
            vm.prank(admin);
            vault.grantRole(operatorRole, sponsors[i]);
        }
    }

    function poolCount() external view returns (uint256) {
        return poolKeys.length;
    }

    function ghostSponsor(bytes32 key) external view returns (address) {
        return _ghost[key].sponsor;
    }

    function ghostClaimed(bytes32 key) external view returns (uint256 total) {
        PoolGhost storage g = _ghost[key];
        for (uint256 i = 0; i < 2; i++) {
            if (g.claimed[i]) total += g.amounts[i];
        }
    }

    /// Every address that can receive money from the vault.
    function receivers() public view returns (address[7] memory r) {
        r = [sponsors[0], sponsors[1], winners[0], winners[1], winners[2], treasuries[0], treasuries[1]];
    }

    // ---------------------------------------------------------------- pool actions

    function createPool(uint256 sponsorSeed, uint256 principal, uint16 feeBps) external {
        if (poolKeys.length >= MAX_POOLS) return;
        address sponsor = sponsors[sponsorSeed % 2];
        principal = bound(principal, 2, 1e12);
        feeBps = uint16(bound(feeBps, 0, 1000));
        bytes32 key = keccak256(abi.encode("pool", ++keyNonce));
        address treasury = vault.treasury();
        vm.prank(sponsor);
        try vault.createPool(key, AgonPrizeVault.PoolKind.Arena, keyNonce, sponsor, principal, feeBps) {
            uint256 fee = (principal * feeBps) / 10_000;
            expectedDelta[sponsor] -= int256(principal + fee);
            expectedDelta[treasury] += int256(fee);
            _ghost[key].sponsor = sponsor;
            poolKeys.push(key);
            calls["createPool"]++;
        } catch { }
    }

    function publishRoot(uint256 poolSeed, uint256 a, uint256 b, uint256 winnerSeed, uint256 window) external {
        (bytes32 key, AgonPrizeVault.Pool memory pool) = _pickIn(poolSeed, AgonPrizeVault.State.Funded);
        if (key == bytes32(0) || pool.state != AgonPrizeVault.State.Funded) return;
        a = bound(a, 1, pool.principal - 1);
        b = bound(b, 1, pool.principal - a);
        _publish(
            key,
            pool.sponsor,
            [winners[winnerSeed % 3], winners[(winnerSeed / 3) % 3]],
            [a, b],
            uint64(time + bound(window, 1, 30 days))
        );
    }

    function _publish(bytes32 key, address sponsor, address[2] memory w, uint256[2] memory amounts, uint64 deadline)
        internal
    {
        bytes32 la = _leaf(0, w[0], amounts[0]);
        bytes32 lb = _leaf(1, w[1], amounts[1]);
        bytes32 root = la < lb ? keccak256(bytes.concat(la, lb)) : keccak256(bytes.concat(lb, la));
        vm.prank(sponsor);
        try vault.publishPayoutRoot(key, root, amounts[0] + amounts[1], deadline) {
            PoolGhost storage g = _ghost[key];
            g.beneficiaries = w;
            g.amounts = amounts;
            g.root = root;
            calls["publishRoot"]++;
        } catch { }
    }

    function claim(uint256 poolSeed, uint256 leafSeed) external {
        (bytes32 key,) = _pickIn(poolSeed, AgonPrizeVault.State.RootPublished);
        if (key == bytes32(0)) return;
        PoolGhost storage g = _ghost[key];
        if (g.root == bytes32(0)) return;
        uint256 i = leafSeed % 2;
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(1 - i, g.beneficiaries[1 - i], g.amounts[1 - i]);
        vm.prank(stranger);
        try vault.claim(key, i, g.beneficiaries[i], g.amounts[i], proof) {
            if (g.claimed[i]) doubleClaim = true;
            g.claimed[i] = true;
            expectedDelta[g.beneficiaries[i]] += int256(g.amounts[i]);
            calls["claim"]++;
        } catch { }
    }

    /// A claim for an amount the root does not hold must never pay.
    function claimForeign(uint256 poolSeed, uint256 leafSeed, uint256 extra) external {
        (bytes32 key,) = _pickIn(poolSeed, AgonPrizeVault.State.RootPublished);
        if (key == bytes32(0)) return;
        PoolGhost storage g = _ghost[key];
        if (g.root == bytes32(0)) return;
        uint256 i = leafSeed % 2;
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(1 - i, g.beneficiaries[1 - i], g.amounts[1 - i]);
        vm.prank(stranger);
        try vault.claim(key, i, g.beneficiaries[i], g.amounts[i] + bound(extra, 1, 1e12), proof) {
            foreignClaim = true;
        } catch { }
    }

    function refundRemaining(uint256 poolSeed) external {
        (bytes32 key, AgonPrizeVault.Pool memory pool) = _pickIn(poolSeed, AgonPrizeVault.State.RootPublished);
        if (key == bytes32(0)) return;
        vm.prank(stranger);
        try vault.refundRemaining(key) {
            expectedDelta[pool.sponsor] += int256(pool.principal - pool.claimedTotal);
            calls["refundRemaining"]++;
        } catch { }
    }

    function refundUnpublished(uint256 poolSeed) external {
        (bytes32 key, AgonPrizeVault.Pool memory pool) = _pickIn(poolSeed, AgonPrizeVault.State.Funded);
        if (key == bytes32(0)) return;
        vm.prank(stranger);
        try vault.refundUnpublished(key) {
            expectedDelta[pool.sponsor] += int256(pool.principal);
            calls["refundUnpublished"]++;
        } catch { }
    }

    function withdrawCredit(uint256 seed) external {
        address who = receivers()[seed % 7];
        vm.prank(who);
        try vault.withdrawCredit() {
            calls["withdrawCredit"]++;
        } catch { }
    }

    // ---------------------------------------------------------------- environment actions

    function warp(uint256 secondsForward) external {
        time += bound(secondsForward, 1, 3 days);
        vm.warp(time);
        calls["warp"]++;
    }

    /// Long enough to pass claim deadlines and the 30-day root publish window.
    function longWarp(uint256 secondsForward) external {
        time += bound(secondsForward, 1 days, 35 days);
        vm.warp(time);
        calls["longWarp"]++;
    }

    /// Paused after about one call in four.
    function setPaused(uint8 seed) external {
        bool want = seed % 4 == 0;
        vm.startPrank(admin);
        if (want && !vault.paused()) vault.pause();
        if (!want && vault.paused()) vault.unpause();
        vm.stopPrank();
        calls["setPaused"]++;
    }

    function switchTreasury(bool second) external {
        vm.prank(admin);
        vault.setTreasury(treasuries[second ? 1 : 0]);
        calls["switchTreasury"]++;
    }

    function setBlocked(uint256 seed, uint8 blockSeed) external {
        usdc.setBlocked(receivers()[seed % 7], blockSeed % 4 == 0);
        calls["setBlocked"]++;
    }

    // ---------------------------------------------------------------- internals

    function _leaf(uint256 index, address beneficiary, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, beneficiary, amount))));
    }

    /// The first pool in `state`, scanning from a random start.
    function _pickIn(uint256 seed, AgonPrizeVault.State state)
        internal
        view
        returns (bytes32 key, AgonPrizeVault.Pool memory pool)
    {
        uint256 n = poolKeys.length;
        for (uint256 k = 0; k < n; k++) {
            bytes32 candidate = poolKeys[(seed % n + k) % n];
            AgonPrizeVault.Pool memory p = vault.getPool(candidate);
            if (p.state == state) return (candidate, p);
        }
    }
}
