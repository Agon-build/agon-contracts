# Static analysis, coverage and mutation testing

Measured on 2026-11-26 on node-services, in a throwaway folder, for the
in-scope files (see `BASELINE.md`). Every result has a verdict: **Fixed**,
**False positive** or **Accepted**, with the reason.

## Tools

- Slither 0.11.3 (PyPI), solc 0.8.24, `--exclude-dependencies`, run per file
  from a copy of `src/` and `lib/`.
- Foundry v1.8.6 `forge coverage --ir-minimum --report lcov`.
- `slither-mutate` (Slither 0.11.3) with Foundry v1.8.6 (see "Tooling notes").
- Aderyn: **not run.** It installs by running a downloaded script; held for
  the owner's approval.

## Slither

96 raw results across the eight in-scope files. Most repeat across files
(each file pulls in its dependencies), and most come from OpenZeppelin. After
removing repeats, these are the distinct results on our code:

| ID | Impact | Detector | Where | Verdict |
| --- | --- | --- | --- | --- |
| S-01 | High | `arbitrary-send-erc20` | `AgonPrizeVault.createPool`, `safeTransferFrom(sponsor, …)` | **False positive.** `createPool` requires `sponsor == msg.sender` (`SponsorMustBeCaller`) and `sponsor != 0` before the transfer, so it can only pull the caller's own approval. Tested in `testFuzz_sponsorMustBeCaller` and the vault invariants (`invariant_sponsor_is_payer`). |
| S-02 | Medium | `reentrancy-no-eth` | `AgonJobEscrowV2._payProvider`: `credits` and `totalCredits` written after the provider transfer | **Accepted.** The job's `status` and `settlement` are written before any call, so the job cannot be settled twice. The only external calls go to the USDC contract fixed at construction (Arc's system USDC). Every caller of `_payProvider` is `nonReentrant`, and `withdrawCredit` is `nonReentrant` too. The write after the call only adds a credit for the address that failed to receive. Checked by `invariant_job_settles_once`, `invariant_escrow_solvent` and `invariant_credits_add_up`. |
| S-03 | Low | `reentrancy-benign` | `AgonJobEscrowV2._send`, `AgonPrizeVault._send`: credit written after the transfer attempt | **Accepted, by design** (PRE-02): the credit is recorded only when the transfer failed, which is known only after the call. Same reasoning as S-02. |
| S-04 | Low | `reentrancy-events` | `AgonPrizeVault.createPool`: `PoolFunded` emitted after the transfers | **Accepted.** The pool is fully written before the transfers; the calls go only to USDC; `createPool` is restricted to the pool operator who is also the sponsor. |
| S-05 | Medium | `incorrect-equality` | `AgonJobEscrowV2.applyProtocolFeeChange` (`effectiveAt == 0`), `AgonProfileRegistry.getProfile` (`agentId == 0`), `AgonServiceRegistryV2.getListing` / `getVersion` (`listingId == 0`, `version == 0`) | **False positive.** Existence checks on storage the contracts write themselves, never comparisons on balances (`INTENDED.md` item 10). |
| S-06 | Medium | `incorrect-equality` | `AgonServiceRegistryV2.profileUsable` (`p.status == Active`) | **False positive.** An enum comparison. |
| S-07 | Low | `timestamp` | every window check in the escrow, vault, Arena and registries | **Accepted.** These are the time windows themselves (hours to days long); a few seconds of drift cannot change an outcome (`INTENDED.md` item 11). Every boundary is tested at the exact second (`Branches.t.sol`, the fuzz suites). |
| S-08 | Low | `shadowing-local` | `AgonArenaV2` constructor parameter `validationRegistry` shadowed the inherited state variable | **Fixed.** Renamed to `validationRegistryAddress`. |
| S-09 | Info | `low-level-calls` | `AgonJobEscrowV2._send`, `AgonPrizeVault._send` | **Accepted, by design.** A low-level call is how a failed transfer becomes a credit instead of a revert (PRE-02). Each arm of its result check is tested with a token that returns no data, false, short data, or has no code (`Branches.t.sol`, `test_send_*`). |
| S-10 | Info | `pragma` | 0.8.24 in our files, `^0.8.20` in OpenZeppelin | **Accepted.** Everything compiles with exactly 0.8.24 (`foundry.toml`). |
| S-11 | Info | `solc-version` | `^0.8.20` "contains known severe issues" | **Accepted after review.** We compile with 0.8.24, which has seven known bugs. None applies: see below. |
| S-12 | Info | `dead-code`, `assembly`, `low-level-calls`, `naming-convention` inside OpenZeppelin | `lib/openzeppelin-contracts` (v5.0.2) | **Out of scope.** Dependency code, unchanged from the tagged OpenZeppelin release. |
| S-13 | Info | `missing-inheritance` | `AgonServiceRegistryV2` should inherit `IAgonServiceRegistry` | **Accepted.** The registry declares its own structs and enums; the interface mirrors them so the escrow and Arena can read the registry without importing it. Inheriting would mean moving every type into the interface. `RegistryInterface.t.sol` checks that a read through the interface returns exactly what the registry stores. Found only when Slither runs on the whole repository (`slither .`); the per-file runs above did not compile the two together. |

### Known bugs of solc 0.8.24

From the Solidity project's `bugs_by_version.json` and `bugs.json` (read
2026-11-26). We build with the legacy pipeline (`via_ir = false`), optimizer on.

| Bug | Fixed in | Applies? |
| --- | --- | --- |
| OverlappingRecursiveStorageStructCopyCorruption (and ViaIR) | 0.8.39 | No. No recursive structs. |
| YulOptimizerKnowledgeBaseStaleBookkeeping | 0.8.38 | No. Needs addresses computed from different values of one reassigned Yul variable; our only inline assembly is in test helpers, and OpenZeppelin's `MerkleProof._efficientHash` uses fixed scratch slots. |
| MemoryByteArrayElementDeleteClearsWholeWord | 0.8.37 | No. No `delete` on an element of a memory `bytes`. |
| SpillSlotCollisionAcrossMutualRecursion | 0.8.37 | No. Via-IR only, and no mutual recursion. |
| UnsoundSpillInMutualRecursion | 0.8.36 | No. Via-IR only, and no mutual recursion. |
| LostStorageArrayWriteOnSlotOverflow | 0.8.32 | No. No storage arrays placed at the end of storage. |

Moving to the newest compiler is an owner decision (it changes the deployed
bytecode and needs the whole suite and the Arc fork run again).

## Coverage

`forge coverage --ir-minimum`, unit and fuzz tests (the invariant run adds
nothing to these figures):

| Contract | Lines | Branches |
| --- | --- | --- |
| AgonJobEscrowV2 | 98.99% | 96.61% (57/59) |
| AgonPrizeVault | 98.18% | 100% (33/33) |
| AgonProfileRegistry | 100% | 95.00% (19/20) |
| AgonServiceRegistryV2 | 100% | 100% (19/19) |
| AgonArena | 97.30% | 100% (21/21) |
| AgonArenaV2 | 100% | 0% (0/1), see below |
| AgonSeasonCommits | 100% | 100% (2/2) |

Every branch or line still reported as missed is exercised by a named test.
The report does not attribute it, because `--ir-minimum` builds with the IR
pipeline at minimum optimisation and its source maps are approximate:

| Where | Reported missed | Exercised by |
| --- | --- | --- |
| `AgonJobEscrowV2` constructor, the two zero-address checks | branch | `EscrowBranchesTest.test_constructor_refuses_each_zero_address` (each of the five addresses) |
| `AgonProfileRegistry` `onlyOwner`, `IdentityDoesNotExist` | branch | `RegistryBranchesTest.test_owner_actions_on_unknown_identity` |
| `AgonArenaV2` constructor, zero evaluator | branch | `ArenaBranchesTest.test_constructors_refuse_each_zero_address` (and the mutant that removes the check is killed) |
| `pause` / `unpause` of the escrow, vault and Arena | function header lines | every pause test, e.g. `test_pause_and_unpause_track_paused_time`, `test_deadlines_move_while_paused` |

## Mutation testing

`slither-mutate` on each in-scope contract, run against that contract's own
test files (fuzz runs cut to 64, invariants left out). A mutant that the
tests do not fail on "survived". Every survivor was then put back in place by
hand and the tests run again (see "Tooling notes", item 3).

| Contract | Mutants that compiled | Survived | Now killed by a new test | Equivalent |
| --- | --- | --- | --- | --- |
| AgonJobEscrowV2 | 307 | 10 | 9 | 1 |
| AgonPrizeVault | 164 | 12 | 11 | 1 |
| AgonProfileRegistry | 221 | 31 (two runs) | 18 | 13 |
| AgonServiceRegistryV2 | 192 | 28 | 17 | 11 |
| AgonArena | 106 | 5 | 5 | 0 |
| AgonArenaV2 | see note | 1 | 1 | 0 |
| AgonSeasonCommits | 21 | 2 | 0 | 2 |

No "revert" mutant survived in any contract: every `revert` and `require`
that was removed made a test fail. AgonArenaV2 was run first, before the per-contract
test lists, and only its survivor was kept, not its total.

### What the survivors showed, and the tests that now catch them

New files: `test/AgonJobEscrowV2.Mutants.t.sol`, `test/AgonPrizeVault.Mutants.t.sol`,
`test/AgonServiceRegistryV2.Mutants.t.sol`, `test/AgonArena.Mutants.t.sol`,
`test/mocks/ReentrantUSDC.sol` (a token that calls back into the contract
during a payout and records how that call ended), and additions to
`test/AgonProfileRegistry.t.sol`. No contract code changed: every gap was in
the tests.

| Contract | Gap the survivor showed | Test |
| --- | --- | --- |
| Escrow | `cancelProtocolFeeChange` without its admin check went unnoticed | `test_cancelProtocolFeeChange_onlyAdmin` |
| Escrow | applying a fee change did not have to clear the pending fee | `test_applyProtocolFeeChange_clearsThePendingChange` |
| Escrow | `nonReentrant` on `acceptSubmission`, `resolveDispute`, `withdrawCredit` | `test_*_blocksReentry` (three) |
| Escrow | `PayoutCredited`, `CreditWithdrawn`, `RejectionAccepted` not checked | `test_*_emits*` (three) |
| Escrow | a job with no fee could still send 0 to the treasury | `test_zeroFeeJob_sendsNothingToTheTreasury` |
| Vault | `whenNotPaused` on `publishPayoutRoot` and `claim` | `test_publishPayoutRoot_refusedWhilePaused`, `test_claim_refusedWhilePaused` |
| Vault | `nonReentrant` on `claim` and `withdrawCredit` | `test_claim_blocksReentry`, `test_withdrawCredit_blocksReentry` |
| Vault | `PrizeClaimed`, `PayoutCredited`, `CreditWithdrawn`, `TreasuryUpdated` not checked | `test_*_emits*` (four) |
| Vault | a zero fee or a zero refund could still be sent | `test_zeroFeePool_doesNotPayTheTreasury`, `test_fullyClaimedPool_refundSendsNothing` |
| Vault | the claim deadline of a pool with no root, after a pause | `test_effectiveClaimDeadline_isZeroBeforeTheRoot_evenAfterAPause` |
| Profiles | `createdAt`, `updatedAt` and the owner record were never read back | `test_bindProfile_recordsOwnerAndTimes`, `test_everyWrite_stampsUpdatedAt_andKeepsCreatedAt` |
| Profiles | a 2,048-byte URI (the limit) was never tried | `test_metadataUri_acceptsExactly2048Bytes` |
| Profiles | identity id 0 when the identity registry has one | `test_currentOwner_isZeroForIdZeroEvenWhenTheRegistryHasIt` |
| Profiles, registry | a 32-bit timestamp cast went unnoticed | the time tests run past 2^32 seconds |
| Registry | the constructor's admin grant was not checked | `test_constructor_grantsTheAdminRole` |
| Registry | fields, times and the event written by `publishVersion` | `test_publishVersion_writesEveryField` |
| Registry | time and event of `setStatus`, time of `setVerificationForVersion` | `test_setStatus_stampsTimeAndEmits`, `test_setVerificationForVersion_stampsTime` |
| Registry | the publisher recorded as `tx.origin` instead of the caller | the publish tests use a different origin |
| Registry | a failed profile read other than MissingIdentity must mean "not usable" | `test_profileUsable_isFalseWhenTheProfileReadFailsForAnotherReason` |
| Arena | `revokeEvaluation` without its verifier check went unnoticed | `test_revokeEvaluation_onlyVerifier` |
| Arena | `whenNotPaused` on `scoreEvaluation`; the stored response hash; two events | `AgonArena.Mutants.t.sol` |
| Arena V2 | constructor zero-evaluator check (Foundry behaviour, "Tooling notes" item 1) | `test_constructors_refuse_each_zero_address` |

### Equivalent mutants

These change the code without changing what it does, so no test can fail on
them.

| Contract | Mutant | Why it is the same |
| --- | --- | --- |
| Profiles, registry (16) | `x == 0` to `x <= 0`, `x != 0` to `x > 0`, on unsigned integers and `bytes32` | an unsigned value is never below 0 |
| Profiles, registry (3) | `status != Active` to `status > Active`, `status == Listed` to `status <= Listed` | `Active` and `Listed` are the first enum values (0) |
| Profiles | `return address(0)` removed from the `catch` in `currentOwner` | the function then returns its default, `address(0)` |
| Registry | `VERIFIER_ROLE` `constant` to `immutable` | same value, read the same way |
| Registry | `nextListingId` `uint256` to `uint128` | 2^128 listings cannot be reached |
| Registry (2) | `Listing storage` to `Listing memory` in `ownerOfListing` and `escrowEligible` | both only read the listing |
| Escrow, vault | `_pausedSince = 0` removed from `unpause` | `_pausedSince` is only read while paused, and `pause()` sets it first |
| Season commits (2) | `root == 0` and `count == 0` to `<= 0` | unsigned, as above |

## Tooling notes for reviewers

Two behaviours of Foundry v1.8.6 made tests look stronger than they were, and
one of `slither-mutate` makes its log misleading. All three matter to anyone
re-running this.

1. **`vm.expectRevert` before `new C(...)` ends the test.** Foundry 1.8 turns
   `new C(...)` in a test into the `deployCode` cheatcode. A constructor revert
   then ends the whole test function, and with an expected revert pending the
   test is reported as passing. Every check after the first was silently
   skipped. Found by a surviving mutant in `AgonArenaV2`. Tests now deploy
   through `DeployHelper.deployOrRevert` (`test/utils/DeployHelper.sol`), an
   external call, so the revert ends only that call. Affected and fixed:
   `Branches.t.sol` (three constructor tests), `AuditFixes.t.sol`
   (`test_profile_registry_refuses_zero_addresses`),
   `AgonServiceRegistryV2.t.sol` (`test_constructorRequiresEveryAuthorityAddress`),
   `AgonJobEscrowV2.t.sol` (`test_constructorPinsFivePercentAndRejectsFeeAboveCap`).
2. **`forge test --fail-fast` exits 0 after a failure.** `slither-mutate`
   adds `--fail-fast` to any test command containing `forge test`. With
   Foundry v1.8.6 the run stops at the first failing test but reports "0
   failed" and exits 0, so every mutant is reported as uncaught. The mutation
   runs here call a wrapper script without `--fail-fast`.
3. **`slither-mutate` sometimes prints the wrong source text.** In its log and
   `patches_files.txt` some mutants show a cut that lands mid-word or inside a
   comment (for example `pendingProtoco//lFeeEffectiveAt = 0;`). The mutant
   file it saves (`mutants-<Contract>/<Contract>/*.sol`) holds the change that
   was really tested, and a `diff` against the source shows it. Every survivor
   above was read from those files and re-run by hand, one at a time, against
   the contract's tests.
