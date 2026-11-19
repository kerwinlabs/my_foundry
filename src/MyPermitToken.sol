// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// @openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {CalledToken} from "./CalledToken.sol";

/// @title MyPermitToken
/// @notice 同时支持 ERC1363 风格回调和 EIP-2612 离线授权的 ERC20 代币：
///         - 继承 `CalledToken`：标准 ERC20，额外提供 `transferAndCall`，
///           转账后回调接收方的 `onTokensReceived`；
///         - 继承 `ERC20Permit`：提供 `permit`，持有者可以离线签名完成 approve。
///
///         配合 `TokenBank.permitDeposit` 使用：
///         owner 离线签名 Permit（spender 填 TokenBank 地址），
///         任意地址把签名提交给 `TokenBank.permitDeposit(owner, amount, deadline, v, r, s)`，
///         一次交易完成“授权 + 转账 + 记账”，owner 本人不需要发交易、也不需要 ETH。
///
///         EIP-712 签名域（domain）：
///         { name: <构造参数 name>, version: "1", chainId, verifyingContract: address(this) }
///         签名结构体：
///         Permit(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
///         其中 nonce 取自 `nonces(owner)`，每成功调用一次 permit 自增 1，防止签名重放。
contract MyPermitToken is CalledToken, ERC20Permit {
    /// @param name_ 代币名称，同时作为 EIP-712 domain 的 name。
    /// @param symbol_ 代币符号。
    /// @param initialSupply 部署时铸造给部署者的初始供应量（最小单位 wei）。
    constructor(string memory name_, string memory symbol_, uint256 initialSupply)
        CalledToken(name_, symbol_, initialSupply)
        ERC20Permit(name_)
    {}
}
