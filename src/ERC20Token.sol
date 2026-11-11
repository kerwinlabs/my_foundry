// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ERC20Token
/// @notice 一个最小实现的 ERC20 代币。部署时把初始供应量全部铸造给部署者。
///         不依赖 OpenZeppelin 等外部库，可直接复制到 Remix 中编译。
contract ERC20Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    /// @notice 代币总供应量。
    uint256 public totalSupply;

    /// @notice 每个地址持有的代币数量。
    mapping(address => uint256) public balanceOf;

    /// @notice owner 授权给 spender 的可用额度。
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error ZeroAddress();
    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    error InsufficientAllowance(address owner, uint256 allowance, uint256 needed);

    constructor(string memory _name, string memory _symbol, uint256 _initialSupply) {
        name = _name;
        symbol = _symbol;
        totalSupply = _initialSupply;
        balanceOf[msg.sender] = _initialSupply;

        emit Transfer(address(0), msg.sender, _initialSupply);
    }

    /// @notice 把 amount 数量的代币从调用者转给 to。
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice 授权 spender 最多可以从调用者账户转走 amount 数量的代币。
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();

        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice 以 spender 身份，从 from 账户转走 amount 数量的代币。
    ///         type(uint256).max 额度视为无限授权，不再扣减。
    function  transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(from, allowed, amount);
            allowance[from][msg.sender] = allowed - amount;
        }

        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();

        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);

        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
    }
}
