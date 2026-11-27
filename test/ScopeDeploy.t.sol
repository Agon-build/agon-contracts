// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";
import { AgonServiceRegistryV2 } from "../src/AgonServiceRegistryV2.sol";
import { AgonJobEscrowV2 } from "../src/AgonJobEscrowV2.sol";
import { AgonPrizeVault } from "../src/AgonPrizeVault.sol";
import { AgonArenaV2 } from "../src/AgonArenaV2.sol";
import { DeployAgonProfileRegistry } from "../script/DeployAgonProfileRegistry.s.sol";
import { DeployAgonServiceRegistryV2 } from "../script/DeployAgonServiceRegistryV2.s.sol";
import { DeployAgonJobEscrowV2 } from "../script/DeployAgonJobEscrowV2.s.sol";
import { DeployAgonPrizeVault } from "../script/DeployAgonPrizeVault.s.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { LocalAgentIdentity, LocalValidationRegistry } from "./AgonV2DeploymentFlow.t.sol";

/// @notice The deploy scripts of the audited scope set the admin they are given (a Safe in
///         production) and leave the deployer with no role.
/// @dev Calls each script's deploy(config) directly so no process env is shared.
contract ScopeDeployTest is Test {
    uint256 private constant DEPLOYER_KEY = 0xB0B;
    bytes32 private constant ADMIN_ROLE = 0x00;

    address private deployer;
    address private safe = makeAddr("safe");
    address private poolOperator = makeAddr("poolOperator");
    address private resolver = makeAddr("resolver");
    address private treasury = makeAddr("treasury");
    LocalAgentIdentity private identity;
    MockUSDC private usdc;

    function setUp() public {
        vm.chainId(5_042_002);
        deployer = vm.addr(DEPLOYER_KEY);
        identity = new LocalAgentIdentity();
        usdc = new MockUSDC();
    }

    function _profiles() private returns (AgonProfileRegistry) {
        return new DeployAgonProfileRegistry().deploy(
            DEPLOYER_KEY, DeployAgonProfileRegistry.Config({ admin: safe, identityRegistry: address(identity) })
        );
    }

    function test_profileRegistry_adminIsTheSafe() public {
        AgonProfileRegistry profiles = _profiles();
        assertTrue(profiles.hasRole(ADMIN_ROLE, safe));
        assertFalse(profiles.hasRole(ADMIN_ROLE, deployer));
        assertEq(address(profiles.identityRegistry()), address(identity));
    }

    function test_profileRegistry_refusesAnIdentityRegistryWithNoCode() public {
        DeployAgonProfileRegistry script = new DeployAgonProfileRegistry();
        vm.expectRevert(bytes("identity registry has no code"));
        script.deploy(DEPLOYER_KEY, DeployAgonProfileRegistry.Config({ admin: safe, identityRegistry: makeAddr("none") }));
    }

    function test_prizeVault_handsAdminToTheSafe() public {
        AgonPrizeVault vault = new DeployAgonPrizeVault().deploy(
            DEPLOYER_KEY,
            DeployAgonPrizeVault.Config({ admin: safe, poolOperator: poolOperator, usdc: address(usdc), treasury: treasury })
        );
        assertTrue(vault.hasRole(ADMIN_ROLE, safe));
        assertFalse(vault.hasRole(ADMIN_ROLE, deployer));
        assertTrue(vault.hasRole(vault.POOL_OPERATOR_ROLE(), poolOperator));
        assertFalse(vault.hasRole(vault.POOL_OPERATOR_ROLE(), deployer));
        assertEq(vault.treasury(), treasury);
    }

    function test_registryV2AndArenaV2_handAdminToTheSafe() public {
        AgonProfileRegistry profiles = _profiles();
        address verifier = makeAddr("verifier");
        address evaluator = makeAddr("evaluator");
        (AgonServiceRegistryV2 registry, AgonArenaV2 arena) = new DeployAgonServiceRegistryV2().deploy(
            DEPLOYER_KEY,
            DeployAgonServiceRegistryV2.Config({
                admin: safe,
                verifier: verifier,
                evaluator: evaluator,
                profileRegistry: address(profiles),
                validationRegistry: address(new LocalValidationRegistry())
            })
        );
        assertTrue(registry.hasRole(ADMIN_ROLE, safe));
        assertFalse(registry.hasRole(ADMIN_ROLE, deployer));
        assertTrue(arena.hasRole(ADMIN_ROLE, safe));
        assertFalse(arena.hasRole(ADMIN_ROLE, deployer));
        assertTrue(registry.hasRole(registry.VERIFIER_ROLE(), verifier));
        assertTrue(arena.hasRole(arena.EVALUATOR_ROLE(), evaluator));
        assertFalse(arena.hasRole(arena.VERIFIER_ROLE(), deployer));
    }

    function test_jobEscrowV2_againstTheV2Registry() public {
        AgonProfileRegistry profiles = _profiles();
        AgonServiceRegistryV2 services = new AgonServiceRegistryV2(safe, address(profiles), safe);
        AgonJobEscrowV2 escrow = new DeployAgonJobEscrowV2().deploy(
            DEPLOYER_KEY,
            DeployAgonJobEscrowV2.Config({
                admin: safe,
                pauser: safe,
                profileRegistry: address(profiles),
                serviceRegistry: address(services),
                usdc: address(usdc),
                disputeResolver: resolver,
                treasury: treasury,
                reviewHours: 24,
                initialFeeBps: 500
            })
        );
        assertTrue(IAccessControl(address(escrow)).hasRole(ADMIN_ROLE, safe));
        assertFalse(IAccessControl(address(escrow)).hasRole(ADMIN_ROLE, deployer));
        assertEq(address(escrow.serviceRegistry()), address(services));
    }
}
