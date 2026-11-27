// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Deploys creation code in its own external call, so a test can expect the constructor to
///         revert and then carry on.
/// @dev Foundry 1.8 compiles `new C(...)` in a test into the `deployCode` cheatcode. A constructor
///      revert there ends the whole test, and with `vm.expectRevert` pending the test is reported as
///      passing, so later checks in it never run. Call `this.deployOrRevert(...)` instead:
///      `vm.expectRevert(E.selector); this.deployOrRevert(abi.encodePacked(type(C).creationCode, abi.encode(args)));`
abstract contract DeployHelper {
    function deployOrRevert(bytes memory code) external returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        if (deployed == address(0)) {
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
