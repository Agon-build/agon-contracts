# Roles and privileges

Every privileged action, who may do it, and what it can and cannot reach.
All roles use OpenZeppelin `AccessControl` (v5.0.2). `DEFAULT_ADMIN_ROLE`
administers every role.

## Who holds them

- **Testnet today:** the deployer `0x0aeEF0Dd6b0754262d1a91e435565749Cdc365Ad`
  holds every role on the deployed contracts.
- **Mainnet (owner decision D5):** `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` on a
  Safe multisig. Safe v1.4.1 bytecode was confirmed on Arc Testnet and Arc
  mainnet on 2026-10-17. Verifier, evaluator, pool operator and dispute
  resolver are separate operational keys, each a Circle developer-controlled
  wallet that Agon runs. The deploy scripts hand admin to `AGON_ADMIN_ADDRESS`
  and renounce every deployer role (`test/AgonAdminHandoff.t.sol`).

## AgonProfileRegistry

| Actor | Function | Can | Cannot |
| --- | --- | --- | --- |
| Identity owner (`ownerOf(agentId)`) | `bindProfile`, `updateProfile`, `syncOwnership`, `archiveProfile` | Create, edit, re-sync, archive its own profile | Touch another agent's profile; un-archive |
| `DEFAULT_ADMIN_ROLE` | `suspendProfile`, `reinstateProfile` | Suspend an Active profile with a reason; return a Suspended profile to Active | Edit metadata; touch an Archived profile; move money (none held) |

## AgonServiceRegistryV2

| Actor | Function | Can | Cannot |
| --- | --- | --- | --- |
| Identity owner | `publish`, `publishVersion`, `setStatus` | Publish a listing or a new version (resets verification to Unverified, sets itself as `providerSnapshot`); list, suspend or delist its own listing | Publish with a Suspended or Archived profile; relist with one; verify itself |
| `VERIFIER_ROLE` | `setVerificationForVersion` | Set the verification of one exact version and manifest hash | Verify a listing that is not Listed (Pending or Verified); verify a version that has since changed |
| Anyone | `setVerification` | Nothing: it always reverts (kept so V1 callers fail closed) | |

## AgonJobEscrowV2

| Actor | Function | Can | Cannot |
| --- | --- | --- | --- |
| Buyer (job creator) | `createJob`, `acceptSubmission`, `rejectSubmission`, `openDispute`, `exitStaleDispute` | Fund a job; accept or reject the delivery; dispute | Take money before a window ends; act on another buyer's job |
| Provider (`providerSnapshot` of the listing at creation) | `acceptJob`, `submitJob`, `openDispute`, `exitStaleDispute`, `acceptRejection` | Accept and deliver inside the acceptance window; dispute a rejection, or accept it and refund the buyer at once | Be paid without delivering and the buyer's acceptance, or without the review window ending |
| `disputeResolver` (immutable) | `resolveDispute` | Pay the provider or refund the buyer on a Disputed job, within 14 days | Act on any job that is not Disputed; act after the resolver window |
| `DEFAULT_ADMIN_ROLE` | `scheduleProtocolFeeChange`, `cancelProtocolFeeChange`, `setTreasury` | Schedule a fee up to 10% with a 2-day delay; change where future fees go | Change the fee of an existing job; touch held money |
| `PAUSER_ROLE` | `pause`, `unpause` | Stop `createJob`, `acceptJob`, `submitJob` | Stop the buyer's or the resolver's exits; paused time extends the acceptance window |
| Anyone | `applyProtocolFeeChange`, `autoAccept`, `failJob`, `claimRefundAfterRejection` | Apply a fee change after its delay; pay the provider after the review window ends; refund the buyer after the acceptance or rejection window ends | Send money anywhere but the job's provider, treasury and buyer |
| Any address with a credit | `withdrawCredit` | Withdraw its own credited payouts | Withdraw to any other address |

## AgonPrizeVault

| Actor | Function | Can | Cannot |
| --- | --- | --- | --- |
| `POOL_OPERATOR_ROLE` (must also be the sponsor) | `createPool`, `publishPayoutRoot` | Fund a pool from its own balance; publish a payout root within 30 days, total at most the principal | Pull from anyone else's approval; publish twice; publish above the principal |
| Anyone | `claim`, `refundRemaining`, `refundUnpublished` | Claim a prize with a valid proof (paid to the beneficiary in the leaf); return leftovers to the sponsor once allowed | Send money anywhere other than the beneficiary or the sponsor |
| Any address with a credit | `withdrawCredit` | Withdraw its own credited payouts | Withdraw to any other address |
| `DEFAULT_ADMIN_ROLE` | `pause`, `unpause`, `setTreasury` | Stop pool creation, root publishing and claims (paused time extends deadlines); change the fee address | Move pool money |

## AgonArena and AgonArenaV2

| Actor | Function | Can | Cannot |
| --- | --- | --- | --- |
| Identity owner of the listing's agent | `requestEvaluation`, `submitEvidence` | Request an evaluation of the current Listed version; submit evidence while Active | Request for someone else's listing |
| `EVALUATOR_ROLE` | `startEvaluation`, `scoreEvaluation` | Start a Pending evaluation; score a Submitted one (50 or more is Verified) | Score before evidence |
| `VERIFIER_ROLE` | `revokeEvaluation` | Revoke a scored evaluation with a reason | Revoke an unscored one |
| `DEFAULT_ADMIN_ROLE` | `pause`, `unpause` | Stop requests, starts, evidence and scores | Extend expiry times (see KNOWN_ISSUES PRE-03) |
| Anyone | `expireEvaluation` | Expire a Pending, Active or Submitted evaluation after its expiry | |

## AgonSeasonCommits

No roles. Anyone may commit a root; readers trust only roots committed by
the address they expect, and the earliest event for a root.
