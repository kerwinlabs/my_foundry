// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC20Token.sol";

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
/// @notice 仿 ERC1363 的代币：transferAndCall 在转账成功后回调接收方。
///         如果接收方没有实现 onTokensReceived，或者返回值不对，整笔交易回滚。
contract CalledToken is ERC20Token {
    error TokensReceiptRejected();

    constructor(string memory _name, string memory _symbol, uint256 _initialSupply)
        ERC20Token(_name, _symbol, _initialSupply)
    {}

    /// @notice 把 amount 数量的代币转给 to，然后回调
    ///         to.onTokensReceived(operator, from, amount, data)。
    function transferAndCall(address to, uint256 amount, bytes calldata data) external returns (bool) {
        // 先完成转账；若回调失败，下面 revert 会把这次转账一并回滚。
        _transfer(msg.sender, to, amount);

        (bool success, bytes memory returndata) = to.call(
            abi.encodeWithSelector(
                ITokensReceiver.onTokensReceived.selector,
                msg.sender,
                msg.sender,
                amount,
                data
            )
        );

        // 仿 ERC1363：必须调用成功且返回正确的 selector。
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
