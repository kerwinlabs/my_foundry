// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {NFTMarketV1} from "./NFTMarketV1.sol";

/// @title NFTMarketV2
/// @notice 在 NFTMarketV1 基础上增加「卖家离线签名上架」功能。
///
///         与 V1 的托管式上架不同，V2 的签名上架流程不需要把 NFT 转入市场：
///         1. 卖家一次性调用 NFT.setApprovalForAll(address(marketV2), true)，
///            之后该卖家所有 NFT 都授权给市场（只需一次）；
///         2. 卖家在链下针对某个 NFT 签名：
///            SellNFT(uint256 tokenId,uint256 price,uint256 nonce,uint256 deadline)
///            其中 nonce = sellNonces(tokenId)，deadline 为签名过期时间；
///         3. 买家把 deadline 与签名 (v, r, s) 传给 buyWithSellerSignature，
///            合约通过 EIP-712 恢复出卖家地址，校验卖家确实是该 NFT 的 owner
///            且已授权市场，然后完成「买家付 TOKEN、卖家转 NFT」。
///
///         取消上架：卖家调用 cancelListing(tokenId) 把该 tokenId 的 nonce + 1，
///         之前用旧 nonce 签出的所有上架签名立即失效（无需保存原签名）；
///         卖家可以用新 nonce 重新签名上架。
///
///         同一份签名只能使用一次（usedSellSignatures 记录 digest），防止重放。
/// @dev 通过 @custom:oz-upgrades-from 指定 V1 作为升级参考合约，供插件做存储布局校验。
/// @custom:oz-upgrades-from NFTMarketV1
contract NFTMarketV2 is NFTMarketV1 {
    /// @notice 卖家签名上架的 EIP-712 结构体类型哈希。
    ///         SellNFT(uint256 tokenId,uint256 price,uint256 nonce,uint256 deadline)
    bytes32 public constant SELL_NFT_TYPEHASH =
        keccak256("SellNFT(uint256 tokenId,uint256 price,uint256 nonce,uint256 deadline)");

    /// @notice 已使用过的卖家签名 digest，防止同一份签名被重复使用。
    mapping(bytes32 => bool) public usedSellSignatures;

    /// @notice tokenId => 当前签名 nonce。
    /// @dev 卖家调用 cancelListing 后 nonce + 1，所有用旧 nonce 签出的上架签名随之失效。
    mapping(uint256 => uint256) public sellNonces;

    event BoughtWithSellerSignature(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        bytes32 digest
    );

    /// @notice 卖家取消某个 NFT 的签名上架（nonce + 1）。
    event SellListingCancelled(uint256 indexed tokenId, address indexed seller, uint256 newNonce);

    /// @notice 卖家不再持有该 NFT（或签名与 tokenId/price/nonce/deadline 不匹配）。
    error NotNFTOwnerForSale(uint256 tokenId, address seller);
    /// @notice 卖家没有把 NFT 授权给本市场。
    error SellerNotApproved(address seller);
    /// @notice 该卖家签名已经被使用过。
    error SignatureAlreadyUsed(bytes32 digest);
    /// @notice 卖家签名已过期。
    error SignatureExpired(uint256 deadline);

    /// @notice 使用卖家离线签名购买 NFT，无需卖家提前上架或托管 NFT。
    /// @dev 签名消息为 EIP-712 结构
    ///      SellNFT(uint256 tokenId,uint256 price,uint256 nonce,uint256 deadline)，
    ///      digest = keccak256("\x19\x01" || DOMAIN_SEPARATOR || structHash)。
    ///      任何人都可以拿着卖家的签名来购买，先到先得；买家需要先 approve 本市场支付 TOKEN。
    /// @param tokenId 要购买的 NFT ID。
    /// @param price 卖家签名中约定的价格，也是买家需要支付的 TOKEN 数量。
    /// @param deadline 签名过期时间戳（秒），block.timestamp 超过后签名失效。
    /// @param v ECDSA 签名参数。
    /// @param r ECDSA 签名参数。
    /// @param s ECDSA 签名参数。
    function buyWithSellerSignature(
        uint256 tokenId,
        uint256 price,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        if (price == 0) revert ZeroPrice();

        // 1. 用当前 nonce 按 EIP-712 编码并恢复签名者，签名者就是卖家。
        uint256 nonce = sellNonces[tokenId];
        bytes32 structHash = keccak256(
            abi.encode(SELL_NFT_TYPEHASH, tokenId, price, nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address seller = ECDSA.recover(digest, v, r, s);

        // 2. 同一份签名只能使用一次。
        if (usedSellSignatures[digest]) revert SignatureAlreadyUsed(digest);

        // 3. 卖家必须仍然是该 NFT 的 owner，并且已 setApprovalForAll 授权市场。
        if (nft.ownerOf(tokenId) != seller) {
            revert NotNFTOwnerForSale(tokenId, seller);
        }
        if (!_isMarketApproved(seller, tokenId)) {
            revert SellerNotApproved(seller);
        }

        if (msg.sender == seller) revert CannotBuyOwnNFT();

        // checks-effects-interactions：先标记签名已使用，再做外部调用。
        usedSellSignatures[digest] = true;

        // 4. 买家支付的 TOKEN 直接转给卖家。
        token.transferFrom(msg.sender, seller, price);

        // 5. 卖家已授权市场，市场直接把 NFT 从卖家转给买家，无需托管。
        nft.safeTransferFrom(seller, msg.sender, tokenId);

        emit BoughtWithSellerSignature(tokenId, msg.sender, seller, price, digest);
    }

    /// @notice 取消某个 NFT 的签名上架，使当前 nonce 下的所有签名立即失效。
    /// @dev 只有该 NFT 当前 owner 可以取消，避免他人恶意让卖家的签名失效。
    ///      取消后 nonce + 1，卖家可用新 nonce 重新签名上架。
    /// @param tokenId 要取消上架的 NFT ID。
    function cancelListing(uint256 tokenId) external {
        if (nft.ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner(tokenId, msg.sender);
        }

        uint256 newNonce = ++sellNonces[tokenId];

        emit SellListingCancelled(tokenId, msg.sender, newNonce);
    }

    /// @dev 市场是否被卖家授权：优先看 setApprovalForAll，也兼容对单个 token 的 approve。
    function _isMarketApproved(address seller, uint256 tokenId) private view returns (bool) {
        return nft.isApprovedForAll(seller, address(this))
            || nft.getApproved(tokenId) == address(this);
    }
}
