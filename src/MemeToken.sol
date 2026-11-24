// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MemeToken
/// @notice Inscription（铭文）风格的 meme 代币，直接继承 OpenZeppelin `ERC20`，
///         标准 ERC20 功能（transfer / approve / transferFrom / balanceOf 等）全部由 OZ 实现。
///         在 ERC20 之上只额外增加两个方法：
///         - `initialize`：由工厂在创建 Clone 后调用一次，写入 symbol、总量上限、每次铸造数量；
///         - `mint`：由工厂调用，每次固定铸造 perMint 个给指定地址，直到铸满 maxSupply。
///
///         本合约作为最小代理（EIP-1167 Clone）的逻辑实现被 delegatecall，
///         所有 Clone 共享这份代码，但各自拥有独立的存储。
///
/// @dev 为什么用 initialize 而不是构造函数传参？
///      最小代理只有 45 字节运行时代码，创建 Clone 时不会执行实现合约的构造函数，
///      Clone 自身也没有构造函数代码。所以 symbol 等参数必须在 Clone 创建之后，
///      通过 `initialize` 写进 Clone 自己的存储槽。
///      同理，OZ `ERC20` 的构造函数只在实现合约部署时执行一次，
///      Clone 里的 `_name` / `_symbol` 永远为空，因此这里重写 `name()` / `symbol()`，
///      改为读取 Clone 自己的存储。
///
///      `factory` 使用 immutable：值被编译进实现合约字节码，Clone delegatecall 时读到的
///      都是同一个工厂地址，用来限制只有工厂能初始化与铸造。
contract MemeToken is ERC20 {
    /// @notice 部署本实现的工厂地址（immutable，所有 Clone 共享）。
    address public immutable factory;

    /// @notice 代币总量上限。注意它不是 ERC20 的 totalSupply。
    uint256 public maxSupply;

    /// @notice 每次铸造的数量。
    uint256 public perMint;

    /// @notice 是否已经初始化，防止 Clone 被重复初始化。
    ///         实现合约在构造函数中置为 true，Clone 的存储中默认为 false。
    bool private _initialized;

    string private _tokenName;
    string private _tokenSymbol;

    event Initialized(string symbol, uint256 maxSupply, uint256 perMint);

    error NotFactory();
    error AlreadyInitialized();
    error EmptySymbol();
    error InvalidAmount();
    error SoldOut();

    constructor() ERC20("", "") {
        factory = msg.sender;
        // 实现合约自身标记为已初始化，避免有人直接对它调用 initialize。
        _initialized = true;
    }

    /// @notice 初始化 Clone 的参数，只能由工厂调用，且只能调用一次。
    /// @param symbol_ 代币符号（同时作为 name）。
    /// @param totalSupply_ 代币总量上限，必须 >= perMint_ 且 > 0。
    /// @param perMint_ 每次铸造的数量，必须 > 0。
    function initialize(string calldata symbol_, uint256 totalSupply_, uint256 perMint_) external {
        if (msg.sender != factory) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        if (bytes(symbol_).length == 0) revert EmptySymbol();
        if (totalSupply_ == 0 || perMint_ == 0 || perMint_ > totalSupply_) revert InvalidAmount();

        _initialized = true;
        _tokenName = symbol_;
        _tokenSymbol = symbol_;
        maxSupply = totalSupply_;
        perMint = perMint_;

        emit Initialized(symbol_, totalSupply_, perMint_);
    }

    /// @notice 给 to 铸造一次 perMint 数量的代币，只能由工厂调用。
    /// @dev `_mint` 由 OZ ERC20 提供：更新 totalSupply 与 balanceOf，并 emit Transfer。
    ///      剩余不足 perMint 时直接 revert（SoldOut）。
    function mint(address to) external {
        if (msg.sender != factory) revert NotFactory();

        uint256 amount = perMint;
        if (totalSupply() + amount > maxSupply) revert SoldOut();

        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    /// @dev 改为读取 Clone 自己的存储（OZ 的 `_name` 在 Clone 中为空）。
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @inheritdoc ERC20
    /// @dev 改为读取 Clone 自己的存储（OZ 的 `_symbol` 在 Clone 中为空）。
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }
}
