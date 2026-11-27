# Invariants

The rules the contracts rely on, in plain words. Each has an ID. Fuzz tests
(1,000 runs each) check one rule per scenario. Stateful Foundry invariant tests in
`test/invariant/` (512 runs; depth 200 for escrow and vault, 50 for the registry)
check them across random call sequences with pauses, fee and treasury changes, new
listing versions and blocklisted addresses. The Test column
is filled in as each test lands.

## Escrow (AgonJobEscrowV2)

| ID | Rule | Test |
| --- | --- | --- |
| INV-ESC-01 | The contract's USDC balance is at least the sum of `amount + fee` over every job that is not settled, plus `totalCredits` | Invariant: `test/invariant/Invariants.t.sol` `invariant_escrow_solvent` |
| INV-ESC-10 | `totalCredits` equals the sum of `credits` over all addresses, and a credit is paid only to its own address | Invariant: `test/invariant/Invariants.t.sol` `invariant_credits_add_up` |
| INV-ESC-02 | A job settles at most once: after Complete or Failed its status and settlement never change | Invariant: `test/invariant/Invariants.t.sol` `invariant_job_settles_once` |
| INV-ESC-03 | A settled job paid exactly one side: ProviderPaid sends `amount` to the provider and `fee` to the treasury; BuyerRefunded sends `amount + fee` to the buyer; nothing else leaves for that job | Fuzz: `test/AgonJobEscrowV2.Fuzz.t.sol` `testFuzz_feeIsComputedAndSnapshotted`; invariant: not applicable (checked per scenario) |
| INV-ESC-04 | A job's fee equals `amount * feeBps / 10,000` with `feeBps` at most 1,000, fixed at creation; later fee changes never alter it | Fuzz: `test/AgonJobEscrowV2.Fuzz.t.sol` `testFuzz_feeIsComputedAndSnapshotted`, `testFuzz_feeAboveCapIsRefused`; invariant: `test/invariant/Invariants.t.sol` `invariant_fee_within_cap` |
| INV-ESC-05 | A job stays bound to the listing version, manifest hash and provider it was created against | Fuzz: `test/AgonJobEscrowV2.Fuzz.t.sol` `testFuzz_jobStaysBoundToItsVersion`; invariant: `test/invariant/Invariants.t.sol` `invariant_job_bound_to_created_version` |
| INV-ESC-06 | Only the buyer can accept or reject a delivery; only the provider can accept the job, submit, or accept a rejection; only the resolver can resolve; `failJob` and `claimRefundAfterRejection` may be called by anyone but pay only the buyer | Fuzz: `test/AgonJobEscrowV2.Fuzz.t.sol` `testFuzz_onlyPartiesAct`, the four window tests; invariant: not applicable (checked per scenario) |
| INV-ESC-07 | Paused time never shortens a provider's acceptance window | Fuzz: `test/AgonJobEscrowV2.Fuzz.t.sol` `testFuzz_pauseExtendsAcceptanceWindow`; invariant: not applicable (checked per scenario) |
| INV-ESC-08 | A client reference is used at most once per buyer | Fuzz: `test/AgonJobEscrowV2.Fuzz.t.sol` `testFuzz_clientReferenceUsedOncePerBuyer`; invariant: not applicable (checked per scenario) |
| INV-ESC-09 | Every money path ends: a job that is not settled can always be settled by someone once its current window passes, even when a party is blocklisted | Invariant: `test/invariant/Invariants.t.sol` `invariant_every_job_can_end` |

## Prize vault (AgonPrizeVault)

| ID | Rule | Test |
| --- | --- | --- |
| INV-VLT-01 | For every pool, `claimedTotal <= payoutTotal <= principal` | Fuzz: `test/AgonPrizeVault.Fuzz.t.sol` `testFuzz_claimsPayEachLeafOnce`; invariant: `test/invariant/Invariants.t.sol` `invariant_vault_claims_never_exceed_principal` |
| INV-VLT-02 | The vault's USDC balance is at least the sum of `principal - claimedTotal` over pools that are not Closed, plus `totalCredits` | Invariant: `test/invariant/Invariants.t.sol` `invariant_vault_solvent` |
| INV-VLT-03 | A leaf index is claimed at most once per pool | Fuzz: `test/AgonPrizeVault.Fuzz.t.sol` `testFuzz_claimsPayEachLeafOnce`; invariant: `test/invariant/Invariants.t.sol` `invariant_leaf_paid_once` |
| INV-VLT-04 | Money leaves a pool only to a beneficiary in its root or to its sponsor | Fuzz: `test/AgonPrizeVault.Fuzz.t.sol` `testFuzz_claimsPayEachLeafOnce`; invariant: `test/invariant/Invariants.t.sol` `invariant_money_goes_only_where_the_rules_say` |
| INV-VLT-05 | Paused time never shortens the root publish window or the claim window | Fuzz: `test/AgonPrizeVault.Fuzz.t.sol` `testFuzz_pauseExtendsBothWindows`; invariant: not applicable (checked per scenario) |
| INV-VLT-06 | A pool's sponsor is the address that paid for it | Fuzz: `test/AgonPrizeVault.Fuzz.t.sol` `testFuzz_sponsorMustBeCaller`; invariant: `test/invariant/Invariants.t.sol` `invariant_sponsor_is_payer` |

## Registry and profiles

| ID | Rule | Test |
| --- | --- | --- |
| INV-REG-01 | A listing's version only grows, by exactly 1 per `publishVersion` | Fuzz: `test/Registries.Fuzz.t.sol` `testFuzz_versionsGrowByOneAndResetVerification`; invariant: `test/invariant/Invariants.t.sol` `invariant_listing_version_only_grows` |
| INV-REG-02 | A new version is always Unverified | Fuzz: `test/Registries.Fuzz.t.sol` `testFuzz_versionsGrowByOneAndResetVerification`; invariant: `test/invariant/Invariants.t.sol` `invariant_listing_version_only_grows` |
| INV-REG-03 | Verified always refers to the current version and manifest hash | Fuzz: `test/Registries.Fuzz.t.sol` `testFuzz_verificationIsScopedToCurrentVersion`, `testFuzz_onlyListedListingsCanBeVerified`; invariant: `test/invariant/Invariants.t.sol` `invariant_verified_means_current_version` |
| INV-REG-04 | A service key is used at most once per agent | Fuzz: `test/Registries.Fuzz.t.sol` `testFuzz_serviceKeyUsedOncePerAgent`; invariant: not applicable (checked per scenario) |
| INV-REG-05 | `escrowEligible` is true only for a Listed, escrow rail, Verified listing with a usable profile | Fuzz: `test/Registries.Fuzz.t.sol` `testFuzz_escrowEligibleNeedsAllFour`; invariant: `test/invariant/Invariants.t.sol` `invariant_escrow_eligible_matches_its_rule` |
| INV-PRF-01 | An Archived profile never changes status again | Fuzz: `test/Registries.Fuzz.t.sol` `testFuzz_archivedProfileStaysArchived`; invariant: `test/invariant/Invariants.t.sol` `invariant_archived_profile_stays_archived` |
| INV-PRF-02 | Only the current identity owner changes a profile, except the admin's suspend and reinstate | Fuzz: `test/Registries.Fuzz.t.sol` `testFuzz_onlyOwnerChangesProfile`, `testFuzz_strangerCannotSuspend`; invariant: not applicable (checked per scenario) |

## Arena

| ID | Rule | Test |
| --- | --- | --- |
| INV-ARN-01 | An evaluation request hash is used at most once | Fuzz: `test/AgonArena.Fuzz.t.sol` `testFuzz_requestHashUsedOnce`; invariant: not applicable (checked per scenario) |
| INV-ARN-02 | A score is set only once and only on a Submitted evaluation; 50 or more is Verified | Fuzz: `test/AgonArena.Fuzz.t.sol` `testFuzz_scoreDecidesOutcomeOnce`, `testFuzz_scoreNeedsEvidenceFirst`; invariant: not applicable (checked per scenario) |
| INV-ARN-03 | An evaluation records the listing version and manifest hash current at request | Fuzz: `test/AgonArena.Fuzz.t.sol` `testFuzz_evaluationKeepsItsScope`; invariant: not applicable (checked per scenario) |
