// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AdminTokenBank
/// @notice 带管理员的 ERC20 Bank，用于多签实战：
///         用户存入 Token，只有管理员可以把 Bank 中的全部 Token 提走。
/// @dev 与 src/TokenBank.sol 相互独立，不修改原 TokenBank。
///      管理员通常设置为 Safe 多签地址；多签通过 execTransaction 调用 withdraw()，
///      此时 msg.sender 就是多签合约，满足 onlyAdmin。
contract AdminTokenBank {
    using SafeERC20 for IERC20;

    /// @notice Bank 管理的 ERC20 代币。
    IERC20 public immutable token;

    /// @notice 管理员地址，部署时直接设置为多签地址。
    address public admin;

    /// @notice 每个地址累计存入的 Token 数量（最小单位）。
    mapping(address => uint256) public deposits;

    /// @notice 累计存入总量，用于展示；管理员提走全部余额后不会清零历史累计值。
    uint256 public totalDeposits;

    event Deposited(address indexed user, uint256 amount, uint256 userDeposit);
    event Withdrawn(address indexed admin, uint256 amount);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error ZeroAddress();
    error ZeroAmount();
    error NotAdmin();
    error IdenticalAdmin();
    error NoFunds();

    /// @param _token 绑定的 ERC20 代币。
    /// @param _admin 管理员地址，通常传 Safe 多签地址。
    constructor(IERC20 _token, address _admin) {
        if (address(_token) == address(0) || _admin == address(0)) revert ZeroAddress();
        token = _token;
        admin = _admin;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @notice 用户存入 amount 数量的 Token。
    /// @dev 调用前需要用户先对 Bank 执行 token.approve(address(this), amount)。
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 userDeposit = deposits[msg.sender] + amount;
        deposits[msg.sender] = userDeposit;
        totalDeposits += amount;

        emit Deposited(msg.sender, amount, userDeposit);
    }

    /// @notice 管理员提走 Bank 中的全部 Token，Token 直接转给管理员（多签地址）。
    /// @dev 由 Safe 多签发起时，Safe 执行后 msg.sender == admin。
    function withdraw() external onlyAdmin {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoFunds();

        token.safeTransfer(admin, balance);

        emit Withdrawn(admin, balance);
    }

    /// @notice 转移管理员权限（可选，由当前管理员调用）。
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (newAdmin == admin) revert IdenticalAdmin();

        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice 查询某个地址累计存入的数量。
    function getDeposit(address user) external view returns (uint256) {
        return deposits[user];
    }
}
