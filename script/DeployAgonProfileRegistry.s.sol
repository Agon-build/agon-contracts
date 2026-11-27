// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { AgonProfileRegistry } from "../src/AgonProfileRegistry.sol";

/// @notice Deploys the profile registry alone, bound to an existing ERC-8004 identity registry.
/// @dev Without --broadcast this is a preflight only. The admin is set in the constructor, so the
///      deployer never holds a role. Env: IDENTITY_REGISTRY_ADDRESS, AGON_ADMIN_ADDRESS (optional,
///      defaults to the deployer).
contract DeployAgonProfileRegistry is Script {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;

    struct Config {
        address admin;
        address identityRegistry;
    }

    function run() external returns (AgonProfileRegistry profiles) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(key != 0, "zero deployer key");
        return deploy(
            key,
            Config({
                admin: vm.envOr("AGON_ADMIN_ADDRESS", vm.addr(key)),
                identityRegistry: vm.envAddress("IDENTITY_REGISTRY_ADDRESS")
            })
        );
    }

    function deploy(uint256 key, Config memory cfg) public returns (AgonProfileRegistry profiles) {
        require(key != 0, "zero deployer key");
        require(block.chainid == ARC_TESTNET_CHAIN_ID, "wrong deployment chain");
        require(cfg.admin != address(0) && cfg.identityRegistry != address(0), "zero address");
        require(cfg.identityRegistry.code.length != 0, "identity registry has no code");

        console2.log("Arc chain ID", block.chainid);
        console2.log("Agon deployer", vm.addr(key));
        console2.log("Agon admin", cfg.admin);
        console2.log("ERC-8004 IdentityRegistry", cfg.identityRegistry);

        vm.startBroadcast(key);
        profiles = new AgonProfileRegistry(cfg.admin, cfg.identityRegistry);
        vm.stopBroadcast();

        console2.log("AgonProfileRegistry", address(profiles));
    }
}
