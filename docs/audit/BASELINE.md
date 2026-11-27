# Audit baseline

The state of the Agon contracts before audit preparation, measured on
2026-11-26 at commit `38e2cd3e`. Every later step is compared with this.

## How it was measured

On node-services, in a throwaway folder:

- Foundry `ghcr.io/foundry-rs/foundry:v1.8.6`: `forge build --sizes`,
  `forge test`, `forge coverage --report summary --ir-minimum`
- Slither 0.11.3 from PyPI with solc 0.8.24, on each in-scope file, run from
  a copy of `src/` and `lib/` with no `foundry.toml` so it compiles with solc
- Dependencies pinned by `foundry.lock`: OpenZeppelin Contracts `v5.0.2`,
  forge-std `v1.16.1`; compiler `0.8.24`, optimizer on, 200 runs

## Scope (owner decision D1)

| File | SHA-256 |
| --- | --- |
| `src/AgonProfileRegistry.sol` | `260ac2db80e2a97fab2a9b2f25cf2e7ea7f9573bc3b80a8f5d5f0cdaea0d3274` |
| `src/AgonServiceRegistryV2.sol` | `f83afd39f3798a88a90a84327a3771d5829c14785e3867482dc2d082cd1652e8` |
| `src/AgonJobEscrowV2.sol` | `370b44f5ac61b9302acae5f8e945b7aa2071477afdd0ef0da03583bcd3dd5b32` |
| `src/AgonPrizeVault.sol` | `0e32ed5eb0624536dcb6a8bf1f4d06a3d2c2caaa1eea7f9d6d17dafe3a10f465` |
| `src/AgonArena.sol` | `7ff5c0e2337721cca9f4a8c7e60ee9f772e86a36e61592368a7c7b07a453741b` |
| `src/AgonArenaV2.sol` | `7bcd53a217a20d83bcd9988ae9808d59b5224d0edad50c0be5d5d9903fda9c00` |
| `src/AgonSeasonCommits.sol` | `385afed6f9c0cf540575ce9592cb57b81c130603262f5d9d1c702b910f36d86c` |

`AgonJobEscrowV2` and `AgonArena` import the out-of-scope `AgonServiceRegistry`
(V1) for its `Listing` type and call the V2 registry through it. Task 2
replaces that with one interface.

## Tests

- **`forge test`: 178 passed, 1 failed, 179 in total.** The failure is
  `AgonSeasonCommitsTest.test_commitIsCheap`. It asserts a call costs under
  15,000 gas; Foundry v1.8.6 measures 32,076 because the measurement includes
  the external call's overhead. The contract is not wrong; the test is fragile.
- **Under `forge coverage` three more tests fail:**
  - `AgonJobEscrowV2Test.test_pauseDoesNotEatTheAcceptanceWindow`
  - `AgonPrizeVaultTest.test_pauseDoesNotEatTheClaimWindow`
  - `AgonPrizeVaultTest.test_pauseExtendsRootPublishWindow`

  Each reads `block.timestamp` after `vm.warp`, which the via-IR coverage build
  caches. They pass in a normal run. They must be rewritten to keep absolute
  times, or coverage figures for these paths cannot be trusted.
- **No fuzz tests. No invariant tests.**

## Coverage (forge coverage, in-scope files)

| File | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| AgonProfileRegistry | 100.00% (57/57) | 88.41% (61/69) | 55.56% (10/18) | 100.00% (10/10) |
| AgonServiceRegistryV2 | 95.71% (67/70) | 85.15% (86/101) | 42.11% (8/19) | 91.67% (11/12) |
| AgonJobEscrowV2 | 93.33% (168/180) | 80.88% (203/251) | 34.55% (19/55) | 96.30% (26/27) |
| AgonPrizeVault | 91.67% (88/96) | 81.29% (113/139) | 37.93% (11/29) | 88.24% (15/17) |
| AgonArena | 89.47% (68/76) | 80.37% (86/107) | 23.81% (5/21) | 81.82% (9/11) |
| AgonArenaV2 | 100.00% (3/3) | 66.67% (2/3) | 0.00% (0/1) | 100.00% (1/1) |
| AgonSeasonCommits | 100.00% (4/4) | 100.00% (5/5) | 100.00% (2/2) | 100.00% (1/1) |

Branch coverage is the weak point: most revert and edge paths are never
exercised. Mutation testing will find these first.

## Slither (raw, before triage)

105 results across the seven files, counted per file, so shared ones repeat.
By kind:

- **High (1):** `arbitrary-send-erc20` in `AgonPrizeVault.createPool`. **False
  positive**: the function requires `sponsor == msg.sender` (fix from the
  2026-10-17 review). To be triaged in `STATIC_ANALYSIS.md`.
- **Medium:** `incorrect-equality`, on `== 0` existence checks in the
  `get*` views and in `applyProtocolFeeChange`. To be triaged.
- **Low:**
  - `timestamp`, on every deadline check. Intended: these are time windows.
  - `reentrancy-events` in `createPool`.
  - `shadowing-local` in the `AgonArenaV2` constructor.
- **Informational:** dependency noise (dead code, assembly and low-level calls
  inside OpenZeppelin), two pragma versions (`0.8.24` and OpenZeppelin's
  `^0.8.20`), and naming.

Aderyn not run yet: it installs by running a downloaded script, which waits
for the owner's approval.

## Known before any review

- A payout to a blocklisted address reverts on Arc, which freezes the job or
  pool (owner decision D3, Task 5).
- The provider cannot release a rejected job's refund early (owner decision
  D4, Task 5).

## After Tasks 5 to 8 (2026-11-26)

Same measurement, at the commit after `17e4f896` plus the Arc fork test.

| | Baseline | Now |
| --- | --- | --- |
| `forge test` (Foundry v1.8.6) | 178 of 179 | 252 of 252 (each invariant contract counted once), fork tests skipped |
| `forge coverage` | 3 extra failures | 252 of 252 |
| Fuzz tests | none | 4 files, 1,000 runs each |
| Invariant tests | none | 15 invariants, 512 runs (depth 200 escrow and vault, 50 registry) |

Branch coverage now: AgonJobEscrowV2 66.1%, AgonPrizeVault 54.6%,
AgonProfileRegistry 80.0%, AgonServiceRegistryV2 57.9%, AgonArena 57.1%,
AgonSeasonCommits 100%. The 95 percent target is Task 9.

### On Arc's own Foundry

Arc Foundry `v0.8.0-4` (`circlefin/arc-foundry`, reports `forge 1.7.1-dev`,
commit `3e95efae`), Linux x86_64 archive checked against its published
SHA-256 `78330505af7dc0d2c9b55fc1aed00d9d063581bb57054949d31ef1c1b4bdbc5e`.

- **`arc-forge test`: 264 passed, 1 suite skipped** (it counts each invariant
  separately; the skipped suite is the fork test, which needs a fork).
- **`arc-forge test --fork-url https://rpc.testnet.arc.io --match-path 'test/fork/*'`
  with `ARC_TESTNET_RPC_URL` set: 3 of 3 passed**
  (`test/fork/ArcBlocklist.fork.t.sol`), against Arc's real USDC at
  `0x3600…0000` and its blocklist precompile at `0x1800…0001`:
  - a normal USDC transfer works and a transfer to the seeded blocklisted
    address `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` reverts with
    "Blocked address";
  - an escrow payout to that address as provider is credited (100 USDC),
    the job settles as ProviderPaid and the treasury still gets its 5 USDC fee;
    the blocked address cannot withdraw the credit while blocked;
  - a prize claimed for that address is credited (60 USDC) and the other
    winner is paid.
- A fork opened inside the test with `vm.createSelectFork` does **not** get
  Arc's precompiles: every USDC transfer then fails in `isBlocklisted` with a
  stack underflow. The test therefore uses the `--fork-url` fork, as Arc's docs
  show, and checks the chain id and a normal transfer first so it cannot pass
  for the wrong reason.

## After Task 9 (2026-11-27)

Measured on node-services with Foundry v1.8.6, in a throwaway folder.

| | After Tasks 5 to 8 | Now |
| --- | --- | --- |
| `forge test` | 252 of 252 | 342 passed, 1 skipped (the Arc fork test, which needs a fork) |
| Branch coverage | 55% to 80% | 95% to 100%; the one AgonArenaV2 branch is tested but not attributed by the tool (`STATIC_ANALYSIS.md`) |
| Slither | 96 raw results, not triaged | every result triaged; one fixed (S-08), the rest false positive or accepted with reasons |
| Mutation testing | not run | every survivor killed by a test or shown equivalent (26 equivalent, listed) |

Two test-suite faults were found and fixed on the way: a constructor revert
expected with `vm.expectRevert` ended the whole test in Foundry 1.8 (six tests
had skipped their later checks), and `forge test --fail-fast` exits 0 after a
failure, which made every mutant look uncaught. Both are described in
`STATIC_ANALYSIS.md`, "Tooling notes for reviewers".

