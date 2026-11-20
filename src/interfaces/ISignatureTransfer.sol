// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISignatureTransfer
/// @notice Uniswap Permit2 的 SignatureTransfer 接口（与官方 ABI 一致的最小实现）。
///         官方源码：
///         https://github.com/Uniswap/permit2/blob/main/src/interfaces/ISignatureTransfer.sol
/// @dev 关键点：Permit2 计算签名哈希时会把 spender（即调用 permitTransferFrom 的
///      msg.sender，这里是 TokenBank）拼进 PermitTransferFrom 结构体，
///      所以用户离线签名时 typed data 里要包含 spender 字段，
///      但链上调用时结构体本身并不传 spender。
interface ISignatureTransfer {
    /// @notice 签名许可的单个代币及最大数量。
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    /// @notice 单笔 SignatureTransfer 的签名许可。
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice 实际转账的目标地址和数量。
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice 校验 owner 的签名，并按 transferDetails 把代币转给 to。
    /// @dev requestedAmount 不能超过 permit.permitted.amount；
    ///      nonce 由 Permit2 的 unordered nonce bitmap 记录，同一 nonce 只能用一次；
    ///      owner 必须事先对 Permit2 合约 approve 对应的代币。
    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    /// @notice Permit2 的 EIP-712 domain separator，
    ///         domain 为 { name: "Permit2", chainId, verifyingContract }（没有 version 字段）。
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
