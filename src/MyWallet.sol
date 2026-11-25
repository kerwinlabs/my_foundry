// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title MyWallet
/// @notice 演示用内联汇编直接读写 owner 所在的存储槽：
///         - `sload(OWNER_SLOT)` 读取 owner；
///         - `sstore(OWNER_SLOT, addr)` 写入 owner。
contract MyWallet {
    string public name;
    mapping (address => bool) private approved;

    /// @notice owner 地址所在的存储槽。
    /// @dev 值等于 keccak256("MyWallet.owner")，用自定义槽避免和 `name`、`approved` 的常规槽冲突。
    ///      内联汇编只支持引用“直接数字常量”，所以这里写成 uint256 十六进制字面量，
    ///      不能写成 `bytes32 constant X = keccak256(...)`。
    uint256 private constant OWNER_SLOT = 0x085ff1332eecdf6418e677a23f34c61a8e64c1b784a9f73571bdaae05dee3a9f;

    /// @dev 从 OWNER_SLOT 读取 owner 并校验调用者。
    modifier auth {
        address ownerAddr;
        // sload 取出整个 32 字节字；赋值给 address 时只保留低 20 字节，
        // 正好是 sstore 写入 address 时左补零的那 20 字节。
        assembly {
            ownerAddr := sload(OWNER_SLOT)
        }
        require(msg.sender == ownerAddr, "Not authorized");
        _;
    }

    constructor(string memory _name) {
        name = _name;
        // 部署者写入 owner 槽（caller() 即 msg.sender）。
        assembly {
            sstore(OWNER_SLOT, caller())
        }
    }

    /// @notice 读取当前 owner。
    function owner() public view returns (address ownerAddr) {
        assembly {
            ownerAddr := sload(OWNER_SLOT)
        }
    }

    /// @notice 转移 owner 权限。
    function transferOwernship(address _addr) external auth {
        require(_addr != address(0), "New owner is the zero address");

        // 先读出当前 owner 做校验，再用汇编写入新 owner。
        address currentOwner;
        assembly {
            currentOwner := sload(OWNER_SLOT)
        }
        require(currentOwner != _addr, "New owner is the same as the old owner");

        assembly {
            sstore(OWNER_SLOT, _addr)
        }
    }
}
