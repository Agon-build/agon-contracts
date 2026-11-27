// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { AgonJobEscrowV2 } from "../../src/AgonJobEscrowV2.sol";
import { AgonPrizeVault } from "../../src/AgonPrizeVault.sol";
import { AgonProfileRegistry } from "../../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../../src/AgonServiceRegistryV2.sol";
import { BlocklistUSDC } from "../mocks/BlocklistUSDC.sol";
import { EscrowHandler } from "./EscrowHandler.sol";
import { VaultHandler } from "./VaultHandler.sol";
import { RegistryHandler } from "./RegistryHandler.sol";

/// @notice Stateful invariants for AgonJobEscrowV2. IDs match docs/audit/INVARIANTS.md.
/// forge-config: default.invariant.depth = 200
contract EscrowInvariants is Test {
    EscrowHandler internal handler;
    AgonJobEscrowV2 internal escrow;
    BlocklistUSDC internal usdc;

    function setUp() public {
        handler = new EscrowHandler();
        escrow = handler.escrow();
        usdc = handler.usdc();
        targetContract(address(handler));
    }

    /// INV-ESC-01: the escrow holds exactly the open jobs' amount plus fee, plus every credit.
    function invariant_escrow_solvent() public view {
        uint256 open;
        for (uint256 i = 0; i < handler.jobCount(); i++) {
            open += escrow.escrowedAmount(handler.jobIds(i));
        }
        assertEq(usdc.balanceOf(address(escrow)), open + escrow.totalCredits());
    }

    /// INV-ESC-10: totalCredits is the sum of every address's credit.
    function invariant_credits_add_up() public view {
        address[6] memory holders = handler.creditHolders();
        uint256 sum;
        for (uint256 i = 0; i < holders.length; i++) {
            sum += escrow.credits(holders[i]);
        }
        assertEq(sum, escrow.totalCredits());
    }

    /// INV-ESC-02: a settled job's status and settlement never change again; settlement and
    /// final status always agree.
    function invariant_job_settles_once() public view {
        assertFalse(handler.settlementChanged());
        for (uint256 i = 0; i < handler.jobCount(); i++) {
            AgonJobEscrowV2.Job memory job = escrow.getJob(handler.jobIds(i));
            if (job.settlement == AgonJobEscrowV2.Settlement.ProviderPaid) {
                assertEq(uint8(job.status), uint8(AgonJobEscrowV2.Status.Complete));
            } else if (job.settlement == AgonJobEscrowV2.Settlement.BuyerRefunded) {
                assertEq(uint8(job.status), uint8(AgonJobEscrowV2.Status.Failed));
            } else {
                assertTrue(
                    job.status != AgonJobEscrowV2.Status.Complete && job.status != AgonJobEscrowV2.Status.Failed
                );
            }
        }
    }

    /// INV-ESC-04: every fee is amount * feeBps / 10,000 with feeBps at most 1,000, as in force at creation.
    function invariant_fee_within_cap() public view {
        assertFalse(handler.creationMismatch());
        assertLe(escrow.protocolFeeBps(), escrow.MAX_PROTOCOL_FEE_BPS());
        for (uint256 i = 0; i < handler.jobCount(); i++) {
            AgonJobEscrowV2.Job memory job = escrow.getJob(handler.jobIds(i));
            assertLe(job.feeBps, escrow.MAX_PROTOCOL_FEE_BPS());
            assertEq(job.fee, (job.amount * job.feeBps) / 10_000);
        }
    }

    /// INV-ESC-05: a job stays bound to the version, manifest, provider and fee it was created with.
    function invariant_job_bound_to_created_version() public view {
        assertFalse(handler.bindingChanged());
        for (uint256 i = 0; i < handler.jobCount(); i++) {
            uint256 id = handler.jobIds(i);
            AgonJobEscrowV2.Job memory job = escrow.getJob(id);
            EscrowHandler.Snapshot memory s = handler.snapshotOf(id);
            assertEq(job.provider, s.provider);
            assertEq(job.listingVersion, s.listingVersion);
            assertEq(job.manifestHash, s.manifestHash);
        }
    }

    /// INV-ESC-09: from any reachable state every open job can still be settled once its window
    /// passes, even with blocked parties, and every credit can be withdrawn once its holder is
    /// unblocked, leaving the escrow empty. Checked on a copy of the state that is then thrown away.
    function invariant_every_job_can_end() public {
        uint256 snapshot = vm.snapshotState();
        address admin = handler.admin();
        if (escrow.paused()) {
            vm.prank(admin);
            escrow.unpause();
        }

        uint256 n = handler.jobCount();
        uint256 t = handler.time();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.jobIds(i);
            AgonJobEscrowV2.Job memory job = escrow.getJob(id);
            uint256 needed;
            if (job.status == AgonJobEscrowV2.Status.Created || job.status == AgonJobEscrowV2.Status.Accepted) {
                needed = escrow.effectiveAcceptanceDeadline(id) + 1;
            } else if (job.status == AgonJobEscrowV2.Status.Submitted) {
                needed = uint256(job.reviewDeadline) + 1;
            } else if (job.status == AgonJobEscrowV2.Status.Rejected) {
                needed = uint256(escrow.rejectedAt(id)) + escrow.REJECTION_WINDOW() + 1;
            } else if (job.status == AgonJobEscrowV2.Status.Disputed) {
                needed = uint256(escrow.disputedAt(id)) + escrow.RESOLVER_WINDOW() + 1;
            }
            if (needed > t) t = needed;
        }
        vm.warp(t);

        address anyone = handler.stranger();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.jobIds(i);
            AgonJobEscrowV2.Job memory job = escrow.getJob(id);
            if (job.status == AgonJobEscrowV2.Status.Created || job.status == AgonJobEscrowV2.Status.Accepted) {
                vm.prank(anyone);
                escrow.failJob(id);
            } else if (job.status == AgonJobEscrowV2.Status.Submitted) {
                vm.prank(anyone);
                escrow.autoAccept(id);
            } else if (job.status == AgonJobEscrowV2.Status.Rejected) {
                vm.prank(anyone);
                escrow.claimRefundAfterRejection(id);
            } else if (job.status == AgonJobEscrowV2.Status.Disputed) {
                vm.prank(job.buyer);
                escrow.exitStaleDispute(id);
            }
            assertEq(escrow.escrowedAmount(id), 0);
        }
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalCredits());

        address[6] memory holders = handler.creditHolders();
        for (uint256 i = 0; i < holders.length; i++) {
            usdc.setBlocked(holders[i], false);
            if (escrow.credits(holders[i]) != 0) {
                vm.prank(holders[i]);
                escrow.withdrawCredit();
            }
        }
        assertEq(escrow.totalCredits(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        vm.revertToState(snapshot);
    }
}

/// @notice Stateful invariants for AgonPrizeVault.
/// forge-config: default.invariant.depth = 200
contract VaultInvariants is Test {
    VaultHandler internal handler;
    AgonPrizeVault internal vault;
    BlocklistUSDC internal usdc;

    function setUp() public {
        handler = new VaultHandler();
        vault = handler.vault();
        usdc = handler.usdc();
        targetContract(address(handler));
    }

    /// INV-VLT-01: for every pool, claimedTotal <= payoutTotal <= principal.
    function invariant_vault_claims_never_exceed_principal() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            AgonPrizeVault.Pool memory pool = vault.getPool(handler.poolKeys(i));
            assertLe(pool.claimedTotal, pool.payoutTotal);
            assertLe(pool.payoutTotal, pool.principal);
        }
    }

    /// INV-VLT-02: the vault holds exactly the unclaimed principal of pools not Closed, plus credits.
    function invariant_vault_solvent() public view {
        uint256 held;
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            AgonPrizeVault.Pool memory pool = vault.getPool(handler.poolKeys(i));
            if (pool.state != AgonPrizeVault.State.Closed) held += pool.principal - pool.claimedTotal;
        }
        assertEq(usdc.balanceOf(address(vault)), held + vault.totalCredits());
    }

    /// INV-VLT-03: each leaf is paid once, and only for what the root holds.
    function invariant_leaf_paid_once() public view {
        assertFalse(handler.doubleClaim());
        assertFalse(handler.foreignClaim());
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            bytes32 key = handler.poolKeys(i);
            assertEq(vault.getPool(key).claimedTotal, handler.ghostClaimed(key));
        }
    }

    /// INV-VLT-04: money reaches only a leaf's beneficiary, the sponsor or the treasury, in exactly
    /// the amounts the rules give (paid out or credited).
    function invariant_money_goes_only_where_the_rules_say() public view {
        address[7] memory r = handler.receivers();
        uint256 sponsorStart = handler.SPONSOR_START();
        for (uint256 i = 0; i < r.length; i++) {
            int256 start = i < 2 ? int256(sponsorStart) : int256(0);
            int256 actual = int256(usdc.balanceOf(r[i]) + vault.credits(r[i]));
            assertEq(actual, start + handler.expectedDelta(r[i]));
        }
        assertEq(usdc.balanceOf(handler.stranger()), 0);
    }

    /// INV-VLT-06: a pool's sponsor is the address that paid for it.
    function invariant_sponsor_is_payer() public view {
        for (uint256 i = 0; i < handler.poolCount(); i++) {
            bytes32 key = handler.poolKeys(i);
            assertEq(vault.getPool(key).sponsor, handler.ghostSponsor(key));
        }
    }
}

/// @notice Stateful invariants for AgonServiceRegistryV2 and AgonProfileRegistry.
contract RegistryInvariants is Test {
    RegistryHandler internal handler;
    AgonServiceRegistryV2 internal services;
    AgonProfileRegistry internal profiles;

    function setUp() public {
        handler = new RegistryHandler();
        services = handler.services();
        profiles = handler.profiles();
        targetContract(address(handler));
    }

    /// INV-REG-01, INV-REG-02: versions only grow, by one each time, and each new version starts Unverified.
    function invariant_listing_version_only_grows() public view {
        assertFalse(handler.versionBroken());
        assertFalse(handler.newVersionNotUnverified());
        for (uint256 i = 0; i < handler.listingCount(); i++) {
            uint256 id = handler.listingIds(i);
            AgonServiceRegistryV2.Listing memory l = services.getListing(id);
            assertEq(l.version, handler.lastVersion(id));
            assertEq(services.getVersion(id, l.version).manifestHash, l.manifestHash);
        }
    }

    /// INV-REG-03: Verified always refers to the current version and manifest hash.
    function invariant_verified_means_current_version() public view {
        assertFalse(handler.staleVerificationAccepted());
        for (uint256 i = 0; i < handler.listingCount(); i++) {
            uint256 id = handler.listingIds(i);
            AgonServiceRegistryV2.Listing memory l = services.getListing(id);
            if (l.verification == AgonServiceRegistryV2.Verification.Verified) {
                assertEq(handler.verifiedVersion(id), l.version);
                assertEq(handler.verifiedManifest(id), l.manifestHash);
            }
        }
    }

    /// INV-REG-05: escrowEligible is exactly Listed, Escrow rail, Verified and a usable profile.
    function invariant_escrow_eligible_matches_its_rule() public view {
        for (uint256 i = 0; i < handler.listingCount(); i++) {
            uint256 id = handler.listingIds(i);
            AgonServiceRegistryV2.Listing memory l = services.getListing(id);
            bool expected = l.status == AgonServiceRegistryV2.ListingStatus.Listed
                && l.paymentRail == AgonServiceRegistryV2.PaymentRail.Escrow
                && l.verification == AgonServiceRegistryV2.Verification.Verified && services.profileUsable(l.agentId);
            assertEq(services.escrowEligible(id), expected);
        }
    }

    /// INV-PRF-01: an Archived profile never changes status again.
    function invariant_archived_profile_stays_archived() public view {
        for (uint256 i = 0; i < 3; i++) {
            uint256 agent = handler.agents(i);
            if (handler.archived(agent)) {
                assertEq(uint8(profiles.getProfile(agent).status), uint8(AgonProfileRegistry.Status.Archived));
                assertFalse(services.profileUsable(agent));
            }
        }
    }
}
