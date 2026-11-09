// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Bank
/// @notice 记录每个地址的累计存款金额，并维护存款金额前 3 名。
///         只有管理员可以提取合约中的全部 ETH。
contract Bank {
    struct TopDepositor {
        address account;
        uint256 amount;
    }

    /// @notice 管理员地址，部署时为部署者，可通过 transferAdmin 转移。
    address public admin;

    /// @notice 每个地址的累计存款金额。
    mapping(address => uint256) public deposits;

    /// @notice 存款金额前 3 名，按金额从高到低排列。
    ///         榜单未满时，空位的 account 为 address(0)。
    TopDepositor[3] public topDepositors;

    /// @notice 合约收到的累计存款总额。
    uint256 public totalDeposits;

    event Deposited(address indexed depositor, uint256 amount, uint256 totalDeposit);
    event TopDepositorsUpdated(address[3] accounts, uint256[3] amounts);
    event Withdrawn(address indexed admin, uint256 amount);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error NotAdmin();
    error IdenticalAdmin();
    error ZeroAddress();
    error ZeroDeposit();
    error NoFunds();
    error TransferFailed();

    constructor() {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert NotAdmin();
        }
        _;
    }

    /// @notice 将管理员权限转移给新地址（可以是普通钱包，也可以是合约）。
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (newAdmin == admin) revert IdenticalAdmin();

        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice 存入 ETH，并更新存款金额前 3 名。
    function deposit() public payable virtual {
        if (msg.value == 0) revert ZeroDeposit();

        uint256 newAmount = deposits[msg.sender] + msg.value;
        deposits[msg.sender] = newAmount;
        totalDeposits += msg.value;

        _updateTopDepositors(msg.sender, newAmount);

        emit Deposited(msg.sender, msg.value, newAmount);
        emit TopDepositorsUpdated(_topAccounts(), _topAmounts());
    }

    /// @notice 管理员提取合约中的全部 ETH。
    function withdraw() external onlyAdmin {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFunds();

        emit Withdrawn(msg.sender, balance);

        (bool success, ) = payable(admin).call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    /// @notice 一次性返回完整的前 3 名榜单。
    function getTopDepositors() external view returns (TopDepositor[3] memory) {
        return topDepositors;
    }

    /// @dev 更新前 3 名榜单：已在榜上的地址更新金额并前移；
    ///      不在榜上的地址在满足条件时插入，原第 3 名被挤出。
    function _updateTopDepositors(address depositor, uint256 amount) private {
        // 已在榜单中：更新金额，并向上移动到正确位置。
        for (uint256 i = 0; i < 3; ++i) {
            if (topDepositors[i].account == depositor) {
                topDepositors[i].amount = amount;
                while (i > 0 && topDepositors[i].amount > topDepositors[i - 1].amount) {
                    TopDepositor memory previous = topDepositors[i - 1];
                    topDepositors[i - 1] = topDepositors[i];
                    topDepositors[i] = previous;
                    --i;
                }
                return;
            }
        }

        // 不在榜单中：找到可插入的位置，其余名次后移。
        for (uint256 i = 0; i < 3; ++i) {
            if (topDepositors[i].account == address(0) || amount > topDepositors[i].amount) {
                for (uint256 j = 2; j > i; --j) {
                    topDepositors[j] = topDepositors[j - 1];
                }
                topDepositors[i] = TopDepositor({account: depositor, amount: amount});
                return;
            }
        }
    }

    function _topAccounts() private view returns (address[3] memory accounts) {
        for (uint256 i = 0; i < 3; ++i) {
            accounts[i] = topDepositors[i].account;
        }
    }

    function _topAmounts() private view returns (uint256[3] memory amounts) {
        for (uint256 i = 0; i < 3; ++i) {
            amounts[i] = topDepositors[i].amount;
        }
    }
}
