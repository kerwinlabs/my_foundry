// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721URIStorageUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";

/// @title UUNFT
/// @notice 基于 OpenZeppelin Contracts Upgradeable 实现的 UUPS 可升级 NFT
/// @dev 部署流程：先部署本合约作为实现合约，再部署 ERC1967Proxy 指向它，
///      并通过代理调用 initialize 完成初始化（实现合约本身的 initialize 已被禁用）。
contract UUNFT is
    Initializable,
    ERC721Upgradeable,
    ERC721URIStorageUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /// @notice 下一个待铸造的 tokenId，从 1 开始
    uint256 public nextTokenId;

    /// @notice 合约版本号，升级实现合约后可修改，用于确认升级是否生效
    string public version;

    /// @dev 锁定实现合约的初始化函数，防止实现合约被他人直接初始化；
    ///      代理合约的 initialize 不受影响，因为代理走的是 delegatecall 到实现合约的逻辑
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化 NFT 合约，只能通过代理调用且只能调用一次
    /// @param initialOwner 管理员地址，拥有铸造和升级权限
    function initialize(address initialOwner) public initializer {
        __ERC721_init("UUNFT", "UUNFT");
        __ERC721URIStorage_init();
        __Ownable_init(initialOwner);

        nextTokenId = 1;
        version = "v1";
    }

    /// @notice 铸造一个 NFT 并设置其 tokenURI，只有 owner 可以调用
    /// @param to 接收者地址
    /// @param uri NFT 元数据地址（如 ipfs://...）
    /// @return tokenId 新铸造的 tokenId
    function safeMint(address to, string memory uri) external onlyOwner returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    /// @notice 修改已存在的 NFT 的 tokenURI，只有 owner 可以调用
    /// @param tokenId 要修改的 tokenId
    /// @param uri 新的元数据地址
    function setTokenURI(uint256 tokenId, string memory uri) external onlyOwner {
        _requireOwned(tokenId);
        _setTokenURI(tokenId, uri);
    }

    /// @notice 设置版本号，用于演示升级后状态仍保存在代理合约中
    /// @param newVersion 新的版本号
    function setVersion(string memory newVersion) external onlyOwner {
        version = newVersion;
    }

    /// @dev 只有 owner 可以升级实现合约
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev 同时继承 ERC721Upgradeable 与 ERC721URIStorageUpgradeable，需要显式合并实现
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    /// @dev 同上，合并两个父合约的 supportsInterface
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
