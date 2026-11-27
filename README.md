# Agon contracts

The smart contracts of [Agon](https://github.com/Agon-build/agon), a marketplace
where people hire AI agents and pay them in USDC on Arc. This repository holds
only the contracts under review, their tests and their deploy scripts. The
context for reviewers is in [`docs/audit/`](docs/audit/), starting with
[`OVERVIEW.md`](docs/audit/OVERVIEW.md).

## Scope

Lines of code exclude blank lines and comments.

| File | Lines of code | Holds money |
| --- | --- | --- |
| `src/AgonProfileRegistry.sol` | 106 | No |
| `src/AgonServiceRegistryV2.sol` | 212 | No |
| `src/AgonJobEscrowV2.sol` | 413 | Yes |
| `src/AgonPrizeVault.sol` | 240 | Yes |
| `src/AgonArena.sol` | 202 | No |
| `src/AgonArenaV2.sol` | 14 | No |
| `src/AgonSeasonCommits.sol` | 13 | No |
| `src/interfaces/IAgonServiceRegistry.sol` | 37 | No |
| `src/interfaces/IERC8004Identity.sol` | 4 | No |
| **Total** | **1,241** | |

Dependencies: OpenZeppelin Contracts v5.0.2 and forge-std v1.16.1 (git
submodules in `lib/`, pinned in `foundry.lock`). Compiler: solc 0.8.24,
optimizer on, 200 runs, legacy pipeline (`via_ir = false`).

Chain: Arc. USDC is Arc's system USDC at
`0x3600000000000000000000000000000000000000`, 6 decimals, with a runtime
blocklist (see [`docs/audit/EXTERNAL.md`](docs/audit/EXTERNAL.md)).

## Commands

Clone with the submodules:

```bash
git clone --recurse-submodules https://github.com/Agon-build/agon-contracts
cd agon-contracts
```

Build and test (Foundry v1.8.6 or Arc Foundry `arc-forge`):

```bash
forge build
forge test
```

Coverage (unit and fuzz tests; the invariant suites add nothing to the figures):

```bash
forge coverage --ir-minimum --report summary --no-match-path "test/invariant/*"
```

Fork test against Arc Testnet, with Arc's real USDC and blocklist. It needs
Arc Foundry, because only a command-line fork gets Arc's precompiles:

```bash
ARC_TESTNET_RPC_URL=https://rpc.testnet.arc.io arc-forge test --fork-url https://rpc.testnet.arc.io --match-path "test/fork/*"
```

Static analysis (Slither 0.11.3):

```bash
slither . --exclude-dependencies --filter-paths "lib/|test/|script/"
```

Mutation testing, one contract at a time, against that contract's tests:

```bash
slither-mutate src/AgonJobEscrowV2.sol --test-dir test --test-cmd "forge test --match-path 'test/{AgonJobEscrowV2*,Branches,AuditFixes}.t.sol'"
```

With Foundry v1.8.6, `slither-mutate` adds `--fail-fast` and Forge then
reports a failed run as passing; see
[`docs/audit/STATIC_ANALYSIS.md`](docs/audit/STATIC_ANALYSIS.md), "Tooling
notes for reviewers", for the wrapper used here and the other two tooling
traps found while preparing this review.

## Results so far

[`docs/audit/BASELINE.md`](docs/audit/BASELINE.md) records each measurement:
the test count, branch coverage per contract, every Slither result with its
verdict, and every mutant that survived with the test that now kills it or
the reason it cannot be killed.

## Deploying

[`docs/audit/DEPLOYMENT.md`](docs/audit/DEPLOYMENT.md) lists each script in
`script/`, its settings and the order. Every contract is deployed without a
proxy and cannot be upgraded.

## Licence

MIT, as stated in each source file.
