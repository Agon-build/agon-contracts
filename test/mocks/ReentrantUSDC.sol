// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { BlocklistUSDC } from "./BlocklistUSDC.sol";

/// @notice Test double that calls back into a target once, during the next transfer out of
///         `watched`, and records how that call ended. Arc's USDC never does this; the tests use
///         it to show every payout path is guarded against reentry.
contract ReentrantUSDC is BlocklistUSDC {
    address public watched;
    address public target;
    bytes public callData;
    bool public armed;
    bool public reentered;
    bytes public reentryResult;

    function arm(address watched_, address target_, bytes calldata data) external {
        watched = watched_;
        target = target_;
        callData = data;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && from == watched) {
            armed = false;
            reentered = true;
            (, reentryResult) = target.call(callData);
        }
        super._update(from, to, value);
    }
}
