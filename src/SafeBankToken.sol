// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SafeBankToken
/// @notice 多签 Bank 实战专用的 ERC20：部署时一次性把初始 Token 铸造给指定账户。
/// @dev 与 src/MyERC20.sol 相互独立，避免和之前的实战共用同一个 Token 地址。
///      初始供应量由部署脚本传入，可一次分发给多个测试账户。
contract SafeBankToken is ERC20 {
    error LengthMismatch();
    error ZeroAddress();

    /// @param name_ Token 名称。
    /// @param symbol_ Token 符号。
    /// @param recipients 初始 Token 的接收地址列表。
    /// @param amounts 与 recipients 一一对应的铸造数量（最小单位）。
    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory recipients,
        uint256[] memory amounts
    ) ERC20(name_, symbol_) {
        if (recipients.length != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            _mint(recipients[i], amounts[i]);
        }
    }
}
