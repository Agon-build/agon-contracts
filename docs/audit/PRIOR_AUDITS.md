# Prior reviews

No external audit before this one. Two internal reviews of the source, both
by the Agon team with its coding agent, both before any mainnet deployment.

## 2026-10-17: contract fixes for audit section 2

All in source, tested (168 forge tests passing at the time), not redeployed.

| Contract | Finding | Fix |
| --- | --- | --- |
| AgonJobEscrowV2 | A rejected job had no exit if nobody disputed | `REJECTION_WINDOW` (7 days), then `claimRefundAfterRejection` refunds amount plus fee; `rejectedAt` mapping |
| AgonJobEscrowV2 | A dispute had no exit if the resolver never acted | `RESOLVER_WINDOW` (14 days), then `exitStaleDispute` refunds the buyer; `disputedAt` mapping |
| AgonPrizeVault | An operator could spend any sponsor's standing approval | `createPool` requires `sponsor == msg.sender` (`SponsorMustBeCaller`) |
| AgonPrizeVault | Principal had no exit if no root was ever published | `ROOT_PUBLISH_WINDOW` (30 days), then `refundUnpublished` |
| AgonPrizeVault | Paused time counted against claim and publish windows | `effectiveClaimDeadline` and `rootPublishDeadline` add paused time |
| Deploy scripts | Deployer kept admin after deployment | Admin handoff to `AGON_ADMIN_ADDRESS`, deployer roles renounced (`test/AgonAdminHandoff.t.sol`) |

Also checked that day: Safe v1.4.1 is deployed on Arc Testnet and Arc mainnet
(bytecode read with `eth_getCode`).

## 2026-11-09: full audit, contracts part (C1 to C5)

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| C1 | Medium | `AgonProfileRegistry` had no way back from Suspended | Fixed: `reinstateProfile` (Suspended to Active only). PRE-01 shows the fix left a path from Archived |
| C2 | Medium | Registry V2 never read profile status | Fixed: `publish`, `publishVersion` and relisting require a usable profile; an agent with no bound profile may still publish (owner decision) |
| C3 | Low | Registry V2 `setStatus` keeps Verified across Delisted and back | Accepted: same version and hash, so no bypass (see `INTENDED.md` 13) |
| C4 | Low to Medium | `AgonPrizeVault.refundRemaining` was operator only | Fixed: open to anyone once every payout is claimed or the window passed; pays only the sponsor |
| C5 | Low | Escrow pause did not stop the acceptance clock | Fixed: paused time extends `effectiveAcceptanceDeadline` |

The verdict then: registry and Arena **Conditional Go** for mainnet after C1
and C2 with admin on a Safe. Escrow and prize vault **No Go** until
redeployed from the fixed source and reviewed externally, which is this
review.
