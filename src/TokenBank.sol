// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokensReceiver} from "./CalledToken.sol";

/// @title TokenBank
/// @notice 记录每个用户存入的 Token 数量，用户可以提取自己之前存入的 Token。
///         使用流程：
///         1. 用户先调用 Token.approve(address(tokenBank), amount) 授权；
///         2. 再调用 TokenBank.deposit(amount) 存入；
///         3. 随时调用 TokenBank.withdraw(amount) 提取。
///         如果使用的是 CalledToken，还可以直接
///         CalledToken.transferAndCall(address(tokenBank), amount, "")，
///         由 onTokensReceived 回调完成记账。
contract TokenBank {
    using SafeERC20 for IERC20;

    /// @notice 存入/提取所使用的 ERC20 代币。
    /// @dev 使用 IERC20 + SafeERC20，兼容 USDT 这类 transfer/transferFrom 不返回 bool 的代币。
    IERC20 public immutable token;

    /// @notice 每个用户当前存入的 Token 数量。
    mapping(address => uint256) public deposits;

    /// @notice 所有用户存入的 Token 总量。
    uint256 public totalDeposits;

    event Deposited(address indexed user, uint256 amount, uint256 userDeposit);
    event Withdrawn(address indexed user, uint256 amount, uint256 userDeposit);

    error ZeroAmount();
    error InsufficientDeposit(uint256 deposit, uint256 needed);
    error NotToken();

    constructor(IERC20 _token) {
        token = _token;
    }

    /// @dev 只允许绑定的 token 合约调用回调，避免别人伪造存款。
    modifier onlyToken() {
        if (msg.sender != address(token)) revert NotToken();
        _;
    }

    /// @notice 存入 amount 数量的 Token。
    /// @dev 需要调用者事先对 TokenBank 完成 approve 授权。
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // 使用 transferFrom 把用户的 Token 转到本合约。
        // SafeERC20 兼容 USDT：其 transferFrom 不返回 bool（无返回值）。
        token.safeTransferFrom(msg.sender, address(this), amount);

        _deposit(msg.sender, amount);
    }

    /// @notice 提取调用者之前存入的 amount 数量的 Token。
    /// @dev 先更新账本再转账（checks-effects-interactions）。
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 userDeposit = deposits[msg.sender];
        if (userDeposit < amount) revert InsufficientDeposit(userDeposit, amount);

        deposits[msg.sender] = userDeposit - amount;
        totalDeposits -= amount;

        token.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, userDeposit - amount);
    }

    /// @notice 查询某个用户当前存入的 Token 数量。
    function getDeposit(address user) external view returns (uint256) {
        return deposits[user];
    }

    /// @notice CalledToken.transferAndCall 的转账回调：
    ///         用户通过 transferAndCall 把 Token 转进本合约后，
    ///         这里把金额记到 from 名下，等价于完成一次 deposit。
    /// @dev 只有绑定的 token 合约可以调用；Token 此时已经转到本合约。
    function onTokensReceived(
        address, /* operator */
        address from,
        uint256 amount,
        bytes calldata /* data */
    )
        external
        onlyToken
        returns (bytes4)
    {
        if (amount == 0) revert ZeroAmount();

        _deposit(from, amount);

        return ITokensReceiver.onTokensReceived.selector;
    }

    /// @dev 更新某个用户的存款账本，deposit 和 onTokensReceived 共用。
    function _deposit(address user, uint256 amount) private {
        uint256 newDeposit = deposits[user] + amount;
        deposits[user] = newDeposit;
        totalDeposits += amount;

        emit Deposited(user, amount, newDeposit);
    }
}
