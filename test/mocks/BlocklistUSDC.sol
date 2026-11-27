// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test double for Arc USDC with its runtime blocklist: a transfer to or
///         from a blocked address reverts, as Arc's docs describe (value transfer rules).
contract BlocklistUSDC is ERC20 {
    mapping(address => bool) public blocked;

    error Blocklisted(address account);

    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from != address(0) && blocked[from]) revert Blocklisted(from);
        if (to != address(0) && blocked[to]) revert Blocklisted(to);
        super._update(from, to, value);
    }
}
