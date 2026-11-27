# Deployment

Every contract is deployed once, without proxies, and cannot be upgraded. A
fix means a new deployment and a move of the app to the new address.

## Scripts (in `script/`)

| Script | Deploys | In the scope repo |
| --- | --- | --- |
| `DeployAgonProfileRegistry.s.sol` | `AgonProfileRegistry` alone | yes |
| `DeployAgonServiceRegistryV2.s.sol` | `AgonServiceRegistryV2` and `AgonArenaV2` | yes |
| `DeployAgonJobEscrowV2.s.sol` | `AgonJobEscrowV2` (checks the V2 registry it is given) | yes |
| `DeployAgonPrizeVault.s.sol` | `AgonPrizeVault` alone | yes |
| `DeployAgonSeasonCommits.s.sol` | `AgonSeasonCommits` | yes |
| `AgonRoleHandoff.sol` | The shared admin handoff each script uses | yes |
| `DeployAgonFoundation.s.sol` | `AgonProfileRegistry` and the V1 `AgonServiceRegistry` | no (V1 registry out of scope) |
| `DeployAgonProtocol.s.sol` | `AgonPrizeVault`, plus the V1 `AgonArena`, V1 `AgonJobEscrow` and `AgonSyndicateRegistry` | no |

`test/ScopeDeploy.t.sol` checks that every in-scope script sets the admin it
is given and leaves the deployer with no role.

## Settings

| Variable | Meaning |
| --- | --- |
| `PRIVATE_KEY` | Deployer key (never committed; read from the shell) |
| `AGON_ADMIN_ADDRESS` | Final admin. On mainnet a Safe (owner decision D5). The deployer grants it `DEFAULT_ADMIN_ROLE` and renounces every role it held |
| `AGON_PAUSER_ADDRESS` | Pauser; defaults to the admin |
| `AGON_VERIFIER_ADDRESS` | Registry and Arena verifier |
| `AGON_EVALUATOR_ADDRESS` | Arena evaluator |
| `AGON_POOL_OPERATOR_ADDRESS` | Prize vault operator |
| `AGON_PROFILE_REGISTRY_ADDRESS`, `AGON_SERVICE_REGISTRY_ADDRESS`, `AGON_VALIDATION_REGISTRY_ADDRESS` | Contracts the new one reads |
| `AGON_USDC_ADDRESS` | `0x3600000000000000000000000000000000000000` |
| `AGON_DISPUTE_RESOLVER_ADDRESS` | Escrow dispute resolver (immutable) |
| `AGON_TREASURY_ADDRESS` | Fee recipient (changeable by the admin) |
| `AGON_DEFAULT_REVIEW_HOURS`, `AGON_INITIAL_PROTOCOL_FEE_BPS` | Escrow defaults (protocol fee at most 1,000) |

## Order

1. Profile registry, then service registry V2 (it reads the profile registry).
2. Arena V2 (reads both).
3. Job escrow V2 (reads the service registry; needs the resolver and treasury).
4. Prize vault and season commits (independent).
5. Hand admin to the Safe; check with `hasRole` that the deployer holds no role.
6. Verify each source on Arcscan (`foundry.toml` has the `arc_testnet`
   explorer entry).

## Deployed today (Arc Testnet, before this audit)

From `deployments/agon-arc-testnet.json`: deployer and admin
`0x0aeEF0Dd6b0754262d1a91e435565749Cdc365Ad`; `AgonProfileRegistry`
`0xE0c7A2545C2f4eE6d2bD797B6f2742c73E640574`; `AgonServiceRegistryV2`
`0xf017290A267A3CEb693544882464a188D9e4a516`; `AgonArenaV2`
`0x05B81dF2F1615BBDEbd837991BAB199F65eCCB83`; `AgonPrizeVault`
`0xd3a538fD48FA81CF102E5b5381B47e46eC176D3b`. They predate the 2026-11-09
fixes and this review. Nothing is on mainnet. After this review, everything
in scope is redeployed from the audited commit.
