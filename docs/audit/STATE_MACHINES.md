# State machines

Every status, every allowed move, who makes it and when. A move not listed
here must revert.

## AgonJobEscrowV2: a job

Windows (all from the job's own fields):

- **Acceptance window:** from `createdAt` for `reviewHours`, moved out by any
  paused time since creation (`effectiveAcceptanceDeadline`). One window
  covers both accepting and delivering.
- **Review window:** from `submittedAt` for `reviewHours` (`reviewDeadline`).
- **Rejection window:** 7 days from `rejectedAt`.
- **Resolver window:** 14 days from `disputedAt`.

| From | To | Function | Who | Condition | Money |
| --- | --- | --- | --- | --- | --- |
| (none) | Created | `createJob` | buyer | not paused; listing `escrowEligible`; fresh client reference; amount above 0; review hours 1 to 720 | buyer pays amount plus fee into the contract |
| Created | Accepted | `acceptJob` | provider | not paused; inside the acceptance window | |
| Accepted | Submitted | `submitJob` | provider | not paused; inside the acceptance window; deliverable hash not zero | sets `reviewDeadline` |
| Submitted | Complete (ProviderPaid) | `acceptSubmission` | buyer | inside the review window | amount to provider, fee to the current treasury |
| Submitted | Complete (ProviderPaid) | `autoAccept` | anyone | after the review window | as above |
| Submitted | Rejected | `rejectSubmission` | buyer | inside the review window; reason hash not zero | none yet |
| Rejected | Disputed | `openDispute` | buyer or provider | inside the rejection window | none yet |
| Rejected | Failed (BuyerRefunded) | `acceptRejection` | provider | any time while Rejected, also while paused | amount plus fee to buyer |
| Rejected | Failed (BuyerRefunded) | `claimRefundAfterRejection` | anyone | after the rejection window | amount plus fee to buyer |
| Disputed | Complete (ProviderPaid) | `resolveDispute(true)` | dispute resolver | inside the resolver window | amount to provider, fee to treasury |
| Disputed | Failed (BuyerRefunded) | `resolveDispute(false)` | dispute resolver | inside the resolver window | amount plus fee to buyer |
| Disputed | Failed (BuyerRefunded) | `exitStaleDispute` | buyer or provider | after the resolver window | amount plus fee to buyer |
| Created or Accepted | Failed (BuyerRefunded) | `failJob` | anyone | after the acceptance window | amount plus fee to buyer |

Complete and Failed are final. A job settles exactly once. Any payout whose transfer fails (a blocklisted
recipient on Arc) is credited to that address instead, and the move still happens; the address takes it
later with `withdrawCredit`.

## AgonServiceRegistryV2: a listing

**Status:**

| From | To | Function | Who | Condition |
| --- | --- | --- | --- | --- |
| (none) | Listed | `publish` | identity owner | usable profile; service key unused for this agent; manifest hash and URI set; category above 0 |
| any | Suspended or Delisted | `setStatus` | identity owner | always allowed |
| any | Listed | `setStatus` | identity owner | usable profile |

**Verification:**

| From | To | Function | Who | Condition |
| --- | --- | --- | --- | --- |
| any | Unverified | `publishVersion` | identity owner | usable profile; new hash and URI; version plus 1; publisher becomes `providerSnapshot` |
| any | any value | `setVerificationForVersion` | verifier | the expected version and hash are current; Pending and Verified only while Listed |

`setStatus` does not change verification (see `INTENDED.md`, and C3 in
`PRIOR_AUDITS.md`).

## AgonProfileRegistry: a profile

| From | To | Function | Who | Condition |
| --- | --- | --- | --- | --- |
| (none) | Active | `bindProfile` | identity owner | not bound before; URI 1 to 2,048 bytes |
| Active | Suspended | `suspendProfile` | admin | |
| Suspended | Active | `reinstateProfile` | admin | |
| any | Archived | `archiveProfile` | identity owner | |

"Usable" for the registry means Active, or no profile bound at all
(owner decision, audit C2).

## AgonPrizeVault: a pool

| From | To | Function | Who | Condition | Money |
| --- | --- | --- | --- | --- | --- |
| (none) | Funded | `createPool` | pool operator who is the sponsor | not paused; key unused; principal above 0; fee at most 10% | sponsor pays principal plus fee; fee to treasury |
| Funded | RootPublished | `publishPayoutRoot` | pool operator | not paused; inside 30 days (plus paused time); payout total at most principal; claim deadline in the future | |
| RootPublished | RootPublished | `claim` | anyone | not paused; before the claim deadline (plus paused time); valid leaf and proof; index unclaimed; claimed total stays at most payout total | amount to beneficiary |
| RootPublished | Closed | `refundRemaining` | anyone | every payout claimed, or the claim deadline passed | principal minus claimed to sponsor |
| Funded | Closed | `refundUnpublished` | anyone | the root publish window passed | principal to sponsor (fee stays with treasury) |

## AgonArena: an evaluation

| From | To | Function | Who | Condition |
| --- | --- | --- | --- | --- |
| (none) | Pending | `requestEvaluation` | identity owner of the listing's agent | not paused; listing Listed; request hash unused; expiry in the future |
| Pending | Active | `startEvaluation` | evaluator | not paused; before expiry |
| Active | Submitted | `submitEvidence` | participant | not paused; before expiry; evidence root set |
| Submitted | Verified or Rejected | `scoreEvaluation` | evaluator | not paused; score 0 to 100 (50 or more passes); response hash set |
| Pending or Active | Expired | `expireEvaluation` | anyone | at or after expiry (a Submitted evaluation waits for its score) |
| Verified or Rejected | Revoked | `revokeEvaluation` | verifier | reason hash set |
