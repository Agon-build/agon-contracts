// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import { AgonProfileRegistry } from "../../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../../src/AgonServiceRegistryV2.sol";
import { AgonJobEscrowV2 } from "../../src/AgonJobEscrowV2.sol";
import { BlocklistUSDC } from "../mocks/BlocklistUSDC.sol";

contract InvariantIdentity is ERC721 {
    constructor() ERC721("External Agent", "AGENT") { }

    function mint(address owner, uint256 id) external {
        _mint(owner, id);
    }

    function move(address from, address to, uint256 id) external {
        _transfer(from, to, id);
    }
}

/// @notice Drives AgonJobEscrowV2 through random sequences of every external function, from the
///         buyers, the two identities that may own the provider agent, the resolver, the admin and a
///         stranger, with time warps, pauses, fee changes, treasury changes, new listing versions and
///         Arc blocklisting (via BlocklistUSDC). Calls that revert are skipped.
/// @dev Ghost state records each job at creation and at settlement so the invariants can check that
///      nothing moves afterwards. Time is kept in `time`, never read back from `block.timestamp`.
contract EscrowHandler is Test {
    struct Snapshot {
        address buyer;
        address provider;
        uint256 listingVersion;
        bytes32 manifestHash;
        uint256 amount;
        uint256 fee;
        uint16 feeBps;
        uint64 createdAt;
    }

    uint256 public constant MAX_JOBS = 25;

    InvariantIdentity public identity;
    AgonProfileRegistry public profiles;
    AgonServiceRegistryV2 public services;
    AgonJobEscrowV2 public escrow;
    BlocklistUSDC public usdc;

    address public admin = makeAddr("inv-admin");
    address public resolver = makeAddr("inv-resolver");
    address public stranger = makeAddr("inv-stranger");
    address[2] public providers = [makeAddr("inv-provider-a"), makeAddr("inv-provider-b")];
    address[2] public buyers = [makeAddr("inv-buyer-a"), makeAddr("inv-buyer-b")];
    address[2] public treasuries = [makeAddr("inv-treasury-a"), makeAddr("inv-treasury-b")];

    uint256 public listingId;
    uint256 public time = 1_000_000;
    uint256 internal refNonce;
    uint256 internal manifestNonce = 1;

    uint256[] public jobIds;
    mapping(uint256 => Snapshot) internal _snapshots;
    mapping(uint256 => bool) public settledSeen;
    mapping(uint256 => uint8) public settledStatus;
    mapping(uint256 => uint8) public settledSettlement;

    /// Set when a job's creation did not match the listing or the fee in force at that moment.
    bool public creationMismatch;
    /// Set when a settled job's status or settlement changed afterwards.
    bool public settlementChanged;
    /// Set when a job's bound fields changed after creation.
    bool public bindingChanged;

    mapping(bytes32 => uint256) public calls;

    constructor() {
        vm.warp(time);
        identity = new InvariantIdentity();
        profiles = new AgonProfileRegistry(admin, address(identity));
        services = new AgonServiceRegistryV2(admin, address(profiles), admin);
        usdc = new BlocklistUSDC();
        escrow = new AgonJobEscrowV2(admin, address(usdc), address(services), resolver, treasuries[0], 24, 500);

        identity.mint(providers[0], 42);
        vm.startPrank(providers[0]);
        profiles.bindProfile(42, "ipfs://profile");
        listingId = services.publish(
            42, keccak256("svc"), _manifest(1), "ipfs://m", 1, AgonServiceRegistryV2.PaymentRail.Escrow
        );
        vm.stopPrank();
        vm.prank(admin);
        services.setVerificationForVersion(listingId, 1, _manifest(1), AgonServiceRegistryV2.Verification.Verified);

        for (uint256 i = 0; i < 2; i++) {
            usdc.mint(buyers[i], 1e18);
            vm.prank(buyers[i]);
            usdc.approve(address(escrow), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- views for the invariants

    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    function snapshotOf(uint256 jobId) external view returns (Snapshot memory) {
        return _snapshots[jobId];
    }

    /// Every address that can ever hold an escrow credit.
    function creditHolders() public view returns (address[6] memory holders) {
        holders = [buyers[0], buyers[1], providers[0], providers[1], treasuries[0], treasuries[1]];
    }

    // ---------------------------------------------------------------- job actions

    function createJob(uint256 buyerSeed, uint256 amount, uint64 reviewHours) external {
        if (jobIds.length >= MAX_JOBS) return;
        address buyer = buyers[buyerSeed % 2];
        amount = bound(amount, 1, 1e12);
        reviewHours = uint64(bound(reviewHours, 0, 720));
        AgonServiceRegistryV2.Listing memory listing = services.getListing(listingId);
        uint16 feeBps = escrow.protocolFeeBps();
        vm.prank(buyer);
        try escrow.createJob(bytes32(++refNonce), listingId, keccak256("terms"), amount, reviewHours) returns (
            uint256 id
        ) {
            AgonJobEscrowV2.Job memory job = escrow.getJob(id);
            _snapshots[id] = Snapshot(
                job.buyer, job.provider, job.listingVersion, job.manifestHash, job.amount, job.fee, job.feeBps, job.createdAt
            );
            if (
                job.buyer != buyer || job.provider != listing.providerSnapshot || job.listingVersion != listing.version
                    || job.manifestHash != listing.manifestHash || job.feeBps != feeBps
                    || job.fee != (amount * feeBps) / 10_000 || job.amount != amount
            ) creationMismatch = true;
            jobIds.push(id);
            calls["createJob"]++;
        } catch { }
        _record();
    }

    /// Move a random open job one legal move forward, by the party allowed to make it. The single
    /// functions below also stay targeted, so moves are tried at any time and by the wrong party too.
    function step(uint256 seed, uint8 choice) external {
        uint256 n = jobIds.length;
        if (n == 0) return;
        for (uint256 k = 0; k < n; k++) {
            uint256 id = jobIds[(seed % n + k) % n];
            AgonJobEscrowV2.Job memory job = escrow.getJob(id);
            if (job.settlement != AgonJobEscrowV2.Settlement.None) continue;
            _stepJob(id, job, choice);
            calls["step"]++;
            _record();
            return;
        }
    }

    function _stepJob(uint256 id, AgonJobEscrowV2.Job memory job, uint8 choice) internal {
        AgonJobEscrowV2.Status s = job.status;
        if (s == AgonJobEscrowV2.Status.Created || s == AgonJobEscrowV2.Status.Accepted) {
            if (choice % 3 == 2) {
                vm.prank(stranger);
                try escrow.failJob(id) {
                    calls["failJob"]++;
                } catch { }
            } else if (s == AgonJobEscrowV2.Status.Created) {
                vm.prank(job.provider);
                try escrow.acceptJob(id) {
                    calls["acceptJob"]++;
                } catch { }
            } else {
                vm.prank(job.provider);
                try escrow.submitJob(id, keccak256(abi.encode("deliverable", id))) {
                    calls["submitJob"]++;
                } catch { }
            }
        } else if (s == AgonJobEscrowV2.Status.Submitted) {
            if (choice % 3 == 0) {
                vm.prank(job.buyer);
                try escrow.acceptSubmission(id) {
                    calls["acceptSubmission"]++;
                } catch { }
            } else if (choice % 3 == 1) {
                vm.prank(stranger);
                try escrow.autoAccept(id) {
                    calls["autoAccept"]++;
                } catch { }
            } else {
                vm.prank(job.buyer);
                try escrow.rejectSubmission(id, keccak256("reason")) {
                    calls["rejectSubmission"]++;
                } catch { }
            }
        } else if (s == AgonJobEscrowV2.Status.Rejected) {
            if (choice % 4 < 2) {
                vm.prank(choice % 4 == 0 ? job.buyer : job.provider);
                try escrow.openDispute(id, keccak256("dispute")) {
                    calls["openDispute"]++;
                } catch { }
            } else if (choice % 4 == 2) {
                vm.prank(job.provider);
                try escrow.acceptRejection(id) {
                    calls["acceptRejection"]++;
                } catch { }
            } else {
                vm.prank(stranger);
                try escrow.claimRefundAfterRejection(id) {
                    calls["claimRefundAfterRejection"]++;
                } catch { }
            }
        } else if (s == AgonJobEscrowV2.Status.Disputed) {
            if (choice % 3 < 2) {
                vm.prank(resolver);
                try escrow.resolveDispute(id, choice % 3 == 0) {
                    calls["resolveDispute"]++;
                } catch { }
            } else {
                vm.prank(job.buyer);
                try escrow.exitStaleDispute(id) {
                    calls["exitStaleDispute"]++;
                } catch { }
            }
        }
    }

    function acceptJob(uint256 seed) external {
        (uint256 id, AgonJobEscrowV2.Job memory job) = _pickIn(seed, AgonJobEscrowV2.Status.Created);
        if (id == 0) return;
        vm.prank(job.provider);
        try escrow.acceptJob(id) {
            calls["acceptJob"]++;
        } catch { }
        _record();
    }

    function submitJob(uint256 seed) external {
        (uint256 id, AgonJobEscrowV2.Job memory job) = _pickIn(seed, AgonJobEscrowV2.Status.Accepted);
        if (id == 0) return;
        vm.prank(job.provider);
        try escrow.submitJob(id, keccak256(abi.encode("deliverable", id))) {
            calls["submitJob"]++;
        } catch { }
        _record();
    }

    function acceptSubmission(uint256 seed) external {
        (uint256 id, AgonJobEscrowV2.Job memory job) = _pickIn(seed, AgonJobEscrowV2.Status.Submitted);
        if (id == 0) return;
        vm.prank(job.buyer);
        try escrow.acceptSubmission(id) {
            calls["acceptSubmission"]++;
        } catch { }
        _record();
    }

    function autoAccept(uint256 seed) external {
        (uint256 id,) = _pickIn(seed, AgonJobEscrowV2.Status.Submitted);
        if (id == 0) return;
        vm.prank(stranger);
        try escrow.autoAccept(id) {
            calls["autoAccept"]++;
        } catch { }
        _record();
    }

    function rejectSubmission(uint256 seed) external {
        (uint256 id, AgonJobEscrowV2.Job memory job) = _pickIn(seed, AgonJobEscrowV2.Status.Submitted);
        if (id == 0) return;
        vm.prank(job.buyer);
        try escrow.rejectSubmission(id, keccak256("reason")) {
            calls["rejectSubmission"]++;
        } catch { }
        _record();
    }

    function openDispute(uint256 seed, bool byProvider) external {
        (uint256 id, AgonJobEscrowV2.Job memory job) = _pickIn(seed, AgonJobEscrowV2.Status.Rejected);
        if (id == 0) return;
        vm.prank(byProvider ? job.provider : job.buyer);
        try escrow.openDispute(id, keccak256("dispute")) {
            calls["openDispute"]++;
        } catch { }
        _record();
    }

    function acceptRejection(uint256 seed) external {
        (uint256 id, AgonJobEscrowV2.Job memory job) = _pickIn(seed, AgonJobEscrowV2.Status.Rejected);
        if (id == 0) return;
        vm.prank(job.provider);
        try escrow.acceptRejection(id) {
            calls["acceptRejection"]++;
        } catch { }
        _record();
    }

    function claimRefundAfterRejection(uint256 seed) external {
        (uint256 id,) = _pickIn(seed, AgonJobEscrowV2.Status.Rejected);
        if (id == 0) return;
        vm.prank(stranger);
        try escrow.claimRefundAfterRejection(id) {
            calls["claimRefundAfterRejection"]++;
        } catch { }
        _record();
    }

    function exitStaleDispute(uint256 seed, bool byProvider) external {
        (uint256 id, AgonJobEscrowV2.Job memory job) = _pickIn(seed, AgonJobEscrowV2.Status.Disputed);
        if (id == 0) return;
        vm.prank(byProvider ? job.provider : job.buyer);
        try escrow.exitStaleDispute(id) {
            calls["exitStaleDispute"]++;
        } catch { }
        _record();
    }

    function resolveDispute(uint256 seed, bool payProvider) external {
        (uint256 id,) = _pickIn(seed, AgonJobEscrowV2.Status.Disputed);
        if (id == 0) return;
        vm.prank(resolver);
        try escrow.resolveDispute(id, payProvider) {
            calls["resolveDispute"]++;
        } catch { }
        _record();
    }

    function failJob(uint256 seed) external {
        (uint256 id,) = _pickIn(seed, seed % 2 == 0 ? AgonJobEscrowV2.Status.Created : AgonJobEscrowV2.Status.Accepted);
        if (id == 0) return;
        vm.prank(stranger);
        try escrow.failJob(id) {
            calls["failJob"]++;
        } catch { }
        _record();
    }

    function withdrawCredit(uint256 holderSeed) external {
        address holder = creditHolders()[holderSeed % 6];
        vm.prank(holder);
        try escrow.withdrawCredit() {
            calls["withdrawCredit"]++;
        } catch { }
        _record();
    }

    // ---------------------------------------------------------------- environment actions

    function warp(uint256 secondsForward) external {
        time += bound(secondsForward, 1, 2 days);
        vm.warp(time);
        calls["warp"]++;
    }

    /// Long enough to pass the 7-day rejection and 14-day resolver windows.
    function longWarp(uint256 secondsForward) external {
        time += bound(secondsForward, 1 days, 20 days);
        vm.warp(time);
        calls["longWarp"]++;
    }

    /// Paused after about one call in four, so the provider side still gets to run.
    function setPaused(uint8 seed) external {
        bool want = seed % 4 == 0;
        vm.startPrank(admin);
        if (want && !escrow.paused()) escrow.pause();
        if (!want && escrow.paused()) escrow.unpause();
        vm.stopPrank();
        calls["setPaused"]++;
        _record();
    }

    function scheduleFee(uint16 feeBps) external {
        feeBps = uint16(bound(feeBps, 0, 1000));
        vm.prank(admin);
        try escrow.scheduleProtocolFeeChange(feeBps) {
            calls["scheduleFee"]++;
        } catch { }
    }

    function applyFee() external {
        vm.prank(stranger);
        try escrow.applyProtocolFeeChange() {
            calls["applyFee"]++;
        } catch { }
    }

    function cancelFee() external {
        vm.prank(admin);
        try escrow.cancelProtocolFeeChange() {
            calls["cancelFee"]++;
        } catch { }
    }

    function switchTreasury(bool second) external {
        vm.prank(admin);
        escrow.setTreasury(treasuries[second ? 1 : 0]);
        calls["switchTreasury"]++;
    }

    /// Block or unblock any credit holder on the USDC mock, as Arc's blocklist would.
    function setBlocked(uint256 holderSeed, uint8 blockSeed) external {
        usdc.setBlocked(creditHolders()[holderSeed % 6], blockSeed % 4 == 0);
        calls["setBlocked"]++;
    }

    /// The agent changes hands and the new owner publishes and verifies a new version. Open jobs
    /// must keep the provider, version and manifest they were created with.
    function newVersion(bool moveOwner) external {
        address owner = identity.ownerOf(42);
        address next = owner;
        if (moveOwner) {
            next = owner == providers[0] ? providers[1] : providers[0];
            identity.move(owner, next, 42);
        }
        uint256 n = ++manifestNonce;
        vm.prank(next);
        services.publishVersion(listingId, _manifest(n), "ipfs://m", AgonServiceRegistryV2.PaymentRail.Escrow);
        uint256 version = services.getListing(listingId).version;
        vm.prank(admin);
        services.setVerificationForVersion(listingId, version, _manifest(n), AgonServiceRegistryV2.Verification.Verified);
        calls["newVersion"]++;
        _record();
    }

    // ---------------------------------------------------------------- internals

    function _manifest(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("manifest", n));
    }

    /// The first job in `status`, scanning from a random start, so multi-step paths get reached.
    function _pickIn(uint256 seed, AgonJobEscrowV2.Status status)
        internal
        view
        returns (uint256 id, AgonJobEscrowV2.Job memory job)
    {
        uint256 n = jobIds.length;
        for (uint256 k = 0; k < n; k++) {
            uint256 candidate = jobIds[(seed % n + k) % n];
            AgonJobEscrowV2.Job memory j = escrow.getJob(candidate);
            if (j.status == status) return (candidate, j);
        }
    }

    /// After every action: remember newly settled jobs, and flag any change to a settled job or to
    /// a job's bound fields.
    function _record() internal {
        for (uint256 i = 0; i < jobIds.length; i++) {
            uint256 id = jobIds[i];
            AgonJobEscrowV2.Job memory job = escrow.getJob(id);
            Snapshot memory s = _snapshots[id];
            if (
                job.buyer != s.buyer || job.provider != s.provider || job.listingVersion != s.listingVersion
                    || job.manifestHash != s.manifestHash || job.amount != s.amount || job.fee != s.fee
                    || job.feeBps != s.feeBps || job.createdAt != s.createdAt
            ) bindingChanged = true;
            if (settledSeen[id]) {
                if (uint8(job.status) != settledStatus[id] || uint8(job.settlement) != settledSettlement[id]) {
                    settlementChanged = true;
                }
            } else if (job.settlement != AgonJobEscrowV2.Settlement.None) {
                settledSeen[id] = true;
                settledStatus[id] = uint8(job.status);
                settledSettlement[id] = uint8(job.settlement);
            }
        }
    }
}
