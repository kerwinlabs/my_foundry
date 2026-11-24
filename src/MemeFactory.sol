// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MemeToken} from "./MemeToken.sol";

/// @title MemeFactory
/// @notice 用 EIP-1167 最小代理（Clone）批量创建 meme Token（`MemeToken`）。
///
///         部署流程：
///         1. 构造函数里 `new MemeToken()` 部署一份实现合约（逻辑合约）；
///         2. `deployInscription` 每次只部署 45 字节的代理，代理通过 delegatecall
///            复用实现合约的代码，再调用 `initialize` 写入该 Clone 自己的参数；
///         3. `mintInscription` 由工厂代替用户调用 Clone 的 `mint`，每次铸 perMint 个。
///
///         相比每个 meme 币都 `new MemeToken()`，Clone 省掉了重复部署完整代码的 gas。
contract MemeFactory {
    /// @notice 所有 Clone 共享的逻辑实现地址。
    address public immutable implementation;

    /// @notice 按创建顺序记录本工厂部署的所有 meme Token。
    address[] public inscriptions;

    /// @notice token 地址 -> 是否由本工厂创建，防止 mintInscription 调用任意合约。
    mapping(address => bool) public isInscription;

    event InscriptionDeployed(
        address indexed token,
        address indexed creator,
        string symbol,
        uint256 totalSupply,
        uint256 perMint
    );

    error CloneCreationFailed();
    error EmptySymbol();
    error InvalidAmount();
    error NotInscription();

    constructor() {
        implementation = address(new MemeToken());
    }

    /// @notice 创建一枚新的 meme Token（最小代理）。
    /// @param symbol 代币符号。
    /// @param totalSupply 代币总量上限。
    /// @param perMint 每次铸造的数量，必须满足 0 < perMint <= totalSupply。
    /// @return token 新部署的 Clone 地址。
    function deployInscription(string calldata symbol, uint256 totalSupply, uint256 perMint)
        external
        returns (address token)
    {
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (totalSupply == 0 || perMint == 0 || perMint > totalSupply) revert InvalidAmount();

        // 1. 部署 45 字节的最小代理
        token = _clone(implementation);

        // 2. 把本次创建的参数写进这个 Clone 自己的存储
        MemeToken(token).initialize(symbol, totalSupply, perMint);

        // 3. 登记，供 mintInscription 校验
        isInscription[token] = true;
        inscriptions.push(token);

        emit InscriptionDeployed(token, msg.sender, symbol, totalSupply, perMint);
    }

    /// @notice 给调用者铸造一次 perMint 数量的代币。
    /// @param tokenAddr deployInscription 返回的 Clone 地址。
    function mintInscription(address tokenAddr) external {
        if (!isInscription[tokenAddr]) revert NotInscription();

        // Clone 内部会校验 msg.sender == factory，并检查是否已铸完。
        MemeToken(tokenAddr).mint(msg.sender);
    }

    /// @notice 已创建的 meme Token 数量。
    function inscriptionCount() external view returns (uint256) {
        return inscriptions.length;
    }

    /// @dev 部署一个 EIP-1167 最小代理，返回其地址。
    ///
    ///      最小代理的部署代码共 55 字节 = 前 10 字节部署引导程序 + 后 45 字节运行时代码：
    ///      - 部署引导程序：把从第 10 字节开始的 45 字节运行时代码 CODECOPY 到内存并 RETURN；
    ///      - 运行时代码（45 字节）：
    ///        10 字节固定前缀 + 20 字节实现合约地址 + 15 字节固定尾部；
    ///        尾部负责把 calldata 转发给实现合约（delegatecall），
    ///        并用 returndatacopy + return/revert 原样返回结果。
    ///
    ///      完整运行时字节码（45 字节）：
    ///      363d3d373d3d3d363d73<implementation>5af43d82803e903d91602b57fd5bf3
    function _clone(address impl) private returns (address instance) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)

            // 写入前 32 字节：10 字节部署引导程序 + 10 字节运行时代码前缀（共 20 字节），
            // 剩余 12 字节由后一次 mstore 覆盖。
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)

            // 在偏移 0x14（20 字节）处写入实现地址（address 左移 96 位对齐到高 20 字节）。
            mstore(add(ptr, 0x14), shl(0x60, impl))

            // 在偏移 0x28（40 字节）处写入 15 字节固定尾部。
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)

            // 从 ptr 开始取 0x37（55）字节作为部署代码执行 create。
            instance := create(0, ptr, 0x37)

            // 更新空闲内存指针（0x37 向上取整到 0x40）。
            mstore(0x40, add(ptr, 0x40))
        }

        if (instance == address(0)) revert CloneCreationFailed();
    }
}
