# External dependencies and chain behaviour

## USDC on Arc

Address `0x3600000000000000000000000000000000000000` on Arc Testnet
(chain 5042002) and Arc mainnet (chain 5042). From the Arc docs, read
2026-11-26 (`arc/references/evm-differences`, "Value transfer rules";
`arc/tutorials/porting-contracts-to-arc`):

- **One asset, two interfaces.** USDC is Arc's native gas token, and
  `0x3600…0000` is its ERC-20 interface. The ERC-20 interface uses 6
  decimals; native value uses 18. Both draw on the same balance. These
  contracts use only the ERC-20 interface (`transfer`, `transferFrom`) and
  never send or accept native value.
- **Blocklist.** A transfer to or from a blocklisted address reverts at
  runtime, even with enough balance. This affects every payout here: the
  provider, buyer, treasury, sponsor and beneficiary are all transfer
  recipients. See KNOWN_ISSUES PRE-02 and owner decision D3.
- **Zero address.** A value transfer to the zero address reverts on Arc. The
  contracts already refuse zero addresses for every recipient they store.
- **`balanceOf` truncates** amounts below 1e-6 USDC. The contracts never read
  `balanceOf` for accounting.
- **`PREVRANDAO` is always 0.** Not used.
- **Arc's test node.** Arc Foundry (`arc-anvil --network arc`, `arc-forge`)
  mimics these rules, and Arc's contract addresses page lists a seeded
  blocklisted test address. Task 8 runs the suite there.

## ERC-8004 identity registry (Arc's deployment, external)

`AgonProfileRegistry` reads `ownerOf(agentId)` through
`interfaces/IERC8004Identity`. A reverting `ownerOf` (missing or burned
identity) is caught and treated as "no owner": `currentOwner` returns
address 0, and owner-only actions revert. Ownership is read live on every
call, so an identity transfer moves control immediately. `ownerSnapshot` is
a record, not an authority.

## OpenZeppelin Contracts v5.0.2

Pinned by `foundry.lock` (rev `dbb6104c`). Used: `AccessControl`, `Pausable`,
`ReentrancyGuard`, `IERC20`, `SafeERC20`, `MerkleProof`. No upgradeable
contracts and no proxies: every contract is deployed once and is immutable.

## Compiler

Solidity `0.8.24`, optimizer on, 200 runs, no via-IR for deployment.
OpenZeppelin files carry `^0.8.20`; Slither reports this as two pragma
versions. Everything compiles with 0.8.24.
