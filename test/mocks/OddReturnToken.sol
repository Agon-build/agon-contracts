// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice A 6-decimal token whose `transfer` can answer in the ways a non-standard ERC-20 does, to
///         exercise every arm of the escrow's and vault's `_send`. `transferFrom` and `approve` are
///         standard, so funding works; only payouts behave oddly.
contract OddReturnToken {
    enum Mode {
        Standard, // moves, returns true
        NoReturn, // moves, returns no data (USDT style)
        ReturnFalse, // does not move, returns false
        ShortReturn // moves, returns one byte
    }

    Mode public mode;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setMode(Mode m) external {
        mode = m;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external {
        Mode m = mode;
        if (m == Mode.ReturnFalse) {
            assembly {
                mstore(0, 0)
                return(0, 32)
            }
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (m == Mode.NoReturn) {
            assembly {
                return(0, 0)
            }
        }
        if (m == Mode.ShortReturn) {
            assembly {
                mstore(0, 0x0100000000000000000000000000000000000000000000000000000000000000)
                return(0, 1)
            }
        }
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}
