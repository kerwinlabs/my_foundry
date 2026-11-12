// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ITokensReceiver
/// @notice 接收方回调接口（仿 ERC1363 的 IERC1363Receiver）。
interface ITokensReceiver {
    /// @notice 收到 Token 后的回调，必须返回本函数的 selector。
    /// @param operator 发起 transferAndCall 的调用者。
    /// @param from 代币的转出方。
    /// @param amount 转入的 Token 数量。
    /// @param data 调用方附带的任意数据。
    function onTokensReceived(
        address operator,
        address from,
        uint256 amount,
        bytes calldata data
    ) external returns (bytes4);
}

/// @title CalledToken
/// @notice 基于 OpenZeppelin ERC20 实现的仿 ERC1363 代币：
///         transferAndCall 在转账成功后回调接收方。
///         如果接收方没有实现 onTokensReceived，或者返回值不对，整笔交易回滚。
contract CalledToken is ERC20 {
    error TokensReceiptRejected();

    /// @param _name 代币名称。
    /// @param _symbol 代币符号。
    /// @param _initialSupply 部署时铸造给部署者的初始供应量。
    constructor(string memory _name, string memory _symbol, uint256 _initialSupply)
        ERC20(_name, _symbol)
    {
        _mint(msg.sender, _initialSupply);
    }

    /// @notice 把 amount 数量的代币转给 to，然后回调
    ///         to.onTokensReceived(operator, from, amount, data)。
    /// @dev 整个流程分两步：① 先改余额完成转账；② 再调用接收方回调。
    ///      回调失败时 revert 会让 ① 的转账一起回滚，
    ///      所以最终要么“转账 + 回调”都成功，要么都不发生。
    function transferAndCall(address to, uint256 amount, bytes calldata data) external returns (bool) {
        // ===== 第 1 步：完成转账 =====
        // _transfer 是 OpenZeppelin ERC20 的内部方法：
        // 从 msg.sender 的余额扣减 amount、给 to 的余额加上 amount，并 emit Transfer。
        // 执行到这里，代币已经真正转到 to 名下了。
        // 如果后面的回调失败并 revert，整个交易回滚，这里的余额变化也会被撤销。
        _transfer(msg.sender, to, amount);

        // ===== 第 2 步：回调接收方 =====
        // to.call(...) 是底层调用：把括号里的字节（calldata）原样发给 to 地址执行。
        // 与普通接口调用不同，to.call 不会因为对方执行失败就自动 revert，
        // 而是返回 (success, 原始返回数据)，由调用者自己检查。
        // 它会把剩余 gas 基本全部转发给 to（EIP-150 的 63/64 规则）。
        //
        // abi.encodeWithSelector(selector, 参数...) 的作用是拼出 calldata：
        //   - ITokensReceiver.onTokensReceived.selector：函数选择器，即 calldata 的前 4 字节；
        //   - (msg.sender, msg.sender, amount, data)：按 ABI 规则编码的 4 个参数。
        // 拼好的字节串等价于调用：
        //   to.onTokensReceived(operator=msg.sender, from=msg.sender, amount, data)
        // operator 和 from 都取 msg.sender，因为 transferAndCall 由持币人自己发起。
        (bool success, bytes memory returndata) = to.call(
            abi.encodeWithSelector(
                ITokensReceiver.onTokensReceived.selector,
                msg.sender,
                msg.sender,
                amount,
                data
            )
        );

        // ===== 第 3 步：校验回调结果 =====
        // 仿 ERC1363，接收方必须是实现了 onTokensReceived 的合约，
        // 且返回值必须正好是 onTokensReceived 的 selector。
        // - !success：to 内部 revert 或 gas 不足，回调失败；
        // - returndata.length < 32：to 是 EOA 或没有该函数（call 本身“成功”但没有返回数据）；
        // - abi.decode(returndata, (bytes4))：把返回数据的前 32 字节按 bytes4 解码，
        //   与 selector 比较，不一致说明接收方返回了错误的值。
        // 任意一项不满足都会 revert，第 1 步的转账也会一并回滚。
        if (
            !success ||
            returndata.length < 32 ||
            abi.decode(returndata, (bytes4)) != ITokensReceiver.onTokensReceived.selector
        ) {
            revert TokensReceiptRejected();
        }

        return true;
    }
}
