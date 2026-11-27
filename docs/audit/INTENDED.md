# Looks risky, but intended

Patterns a reviewer or a tool may flag, with the reason each is deliberate.
If one of these is wrong for a reason we have not seen, that is a finding.

## Escrow

1. **`autoAccept` is open to anyone.** After the review window the buyer has
   had their chance to reject; anyone (Agon's worker, the provider) may then
   pay the provider. The money can only go to the provider and treasury
   fixed in the job.
2. **`applyProtocolFeeChange` is open to anyone.** It only applies a change
   the admin scheduled at least 2 days earlier, at most 10%. Each job keeps
   the fee it was created with.
3. **One window for accepting and delivering.** `acceptanceDeadline` is
   `reviewHours` after creation, and `submitJob` must also land inside it.
   The buyer's review window then runs for the same length after submission.
4. **A buyer cannot cancel before the acceptance window ends.** The provider
   is given the full window to start; the buyer's exit is `failJob` after it.
5. **The fee goes to the treasury current at settlement**, not the one at
   creation. The treasury is Agon's own address; changing it changes where
   future fee payments land.
6. **Pause stops only the provider's side** (`createJob`, `acceptJob`,
   `submitJob`). The buyer's and resolver's exits and `autoAccept` keep
   working while paused, so pausing can never trap money. Paused time
   extends the acceptance window so the provider loses nothing to a pause.
7. **A rejection waits 7 days before the refund.** The provider gets that
   time to dispute a rejection it disagrees with (owner decision D4 adds a
   way for the provider to waive it).
8. **The fee is refunded with the amount on every refund path.** The job
   never completed, so Agon earned nothing.
9. **The provider is the listing's `providerSnapshot` at creation.** A later
   version from a new identity owner does not redirect an existing job's
   payment.
10. **Strict equalities on zero** (`listingId == 0`, `jobId == 0`, `poolKey ==
    bytes32(0)`, `effectiveAt == 0`) are existence checks on storage we
    write, never comparisons on balances. Slither's `incorrect-equality`
    flags them.
11. **Timestamps decide every window.** The windows are hours or days long
    (review 1 to 720 hours, rejection 7 days, resolver 14 days, root publish 30
    days), so a few seconds of timestamp drift cannot change an outcome.

12a. **A failed payout is credited, not retried.** `_send` makes one transfer attempt; on failure
    the amount goes to `credits`. A caller who forwards too little gas could turn a direct
    payment into a credit; the recipient loses nothing and withdraws it with `withdrawCredit`.
12b. **`failJob` and `claimRefundAfterRejection` are open to anyone after their window.** On Arc
    a blocklisted address cannot send transactions, so a blocked buyer could not end its own job.
    The money can still go only to the buyer.
12c. **`withdrawCredit` pays only the caller.** A blocklisted account must not be able to move
    its funds to another address.

## Registry and profiles

12. **An agent with no profile may publish** (owner decision, audit C2 of
    2026-11-09). A bound profile that is Suspended or Archived blocks
    publishing, new versions and relisting.
13. **`setStatus` keeps verification.** Delisting and relisting the same
    version keeps Verified; the content did not change (audit C3, Low,
    accepted).
14. **`setVerification` always reverts.** It is kept so integrations still
    calling the V1 selector fail closed.
15. **`profileUsable` reads the profile through try/catch** and treats only
    `MissingIdentity` as "no profile". Any other failure counts as not usable.

## Prize vault

16. **`createPool` takes a `sponsor` argument but requires `sponsor ==
    msg.sender`** (audit fix of 2026-10-17). Slither's `arbitrary-send-erc20`
    flags the `transferFrom(sponsor, …)`; it cannot pull from anyone else.
17. **Refunds are open to anyone** and pay only the sponsor.
18. **The pool fee goes to the treasury at funding** and is not refunded if
    the root is never published.
19. **A pause that starts after the claim deadline still extends it.** That
    only gives claimants more time.

## Arena and commits

20. **`AgonSeasonCommits` lets anyone commit any root.** It stores nothing;
    readers trust only the committer address they expect and the earliest
    event for a root.
21. **`validationRegistry` is stored but not called** by the Arena on chain.
    It names the ERC-8004 validation registry that the request and response
    hashes refer to, so readers know where to look them up.
