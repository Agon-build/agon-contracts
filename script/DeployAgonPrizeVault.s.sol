// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AgonPrizeVault } from "../src/AgonPrizeVault.sol";
import { AgonRoleHandoff } from "./AgonRoleHandoff.sol";

/// @notice Deploys the prize vault alone.
/// @dev Without --broadcast this is a preflight only.
///      Env: AGON_USDC_ADDRESS, AGON_TREASURY_ADDRESS, AGON_ADMIN_ADDRESS (optional, defaults to the
///      deployer; when set, the deployer hands DEFAULT_ADMIN_ROLE to it and renounces every role),
///      AGON_POOL_OPERATOR_ADDRESS (optional, defaults to the admin).
contract DeployAgonPrizeVault is Script, AgonRoleHandoff {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;

    struct Config {
        address admin;
        address poolOperator;
        address usdc;
        address treasury;
    }

    function run() external returns (AgonPrizeVault vault) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(key != 0, "zero deployer key");
        address admin = vm.envOr("AGON_ADMIN_ADDRESS", vm.addr(key));
        return deploy(
            key,
            Config({
                admin: admin,
                poolOperator: vm.envOr("AGON_POOL_OPERATOR_ADDRESS", admin),
                usdc: vm.envAddress("AGON_USDC_ADDRESS"),
                treasury: vm.envAddress("AGON_TREASURY_ADDRESS")
            })
        );
    }

    function deploy(uint256 key, Config memory cfg) public returns (AgonPrizeVault vault) {
        require(key != 0, "zero deployer key");
        require(block.chainid == ARC_TESTNET_CHAIN_ID, "wrong deployment chain");
        address deployer = vm.addr(key);
        require(cfg.admin != address(0) && cfg.poolOperator != address(0), "zero admin");
        require(cfg.treasury != address(0), "zero treasury");
        require(cfg.usdc.code.length != 0, "USDC has no deployed bytecode");

        console2.log("Arc chain ID", block.chainid);
        console2.log("Agon deployer", deployer);
        console2.log("Agon admin", cfg.admin);
        console2.log("Agon pool operator", cfg.poolOperator);
        console2.log("Agon USDC", cfg.usdc);
        console2.log("Agon treasury", cfg.treasury);

        vm.startBroadcast(key);
        vault = new AgonPrizeVault(deployer, cfg.usdc, cfg.treasury);
        _setupRoles(IAccessControl(address(vault)), _one(vault.POOL_OPERATOR_ROLE(), cfg.poolOperator), deployer, cfg.admin);
        vm.stopBroadcast();

        console2.log("AgonPrizeVault", address(vault));
    }
}
