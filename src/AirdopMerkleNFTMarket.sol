// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title AirdopMerkleNFTMarket
/// @notice 带默克尔树白名单的 NFT 市场：
///         - 卖家 `list` 上架 NFT（NFT 托管到市场）；
///         - 白名单用户（用 Merkle Proof 证明）才能 `buyNFT`；
///         - 支付代币是支持 EIP-2612 的 ERC20Permit（例如 `MyPermitToken`），
///           用户可以离线签名，由本合约的 `permitPrePay` 代为调用 `token.permit`，
///           把市场设为 spender 完成授权，省掉一笔单独的 approve 交易；
///         - `multicall` 基于 delegatecall，允许把 `permitPrePay` 和 `buyNFT`
///           打包进同一笔交易：授权 + 购买一次完成。
///
///         白名单叶子：`keccak256(abi.encodePacked(user))`。
///         前端/脚本构造 Merkle 树时必须使用同样的叶子格式。
contract AirdopMerkleNFTMarket is IERC721Receiver {
    using SafeERC20 for IERC20;

    /// @notice 支付代币（同时也是 ERC20Permit 合约）。
    IERC20 public immutable token;

    /// @notice 被交易的 NFT。
    IERC721 public immutable nft;

    /// @notice 管理员地址，可以更新白名单默克尔根。
    address public immutable admin;

    /// @notice 白名单默克尔根。
    bytes32 public merkleRoot;

    /// @notice 上架信息。
    struct Listing {
        address seller;
        uint256 price;
    }

    /// @notice tokenId => 上架信息；seller 为零地址表示未上架。
    mapping(uint256 => Listing) public listings;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Bought(uint256 indexed tokenId, address indexed buyer, address indexed seller, uint256 price);
    event Delisted(uint256 indexed tokenId, address indexed seller);
    event MerkleRootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);
    event PermitPrePaid(address indexed owner, uint256 amount, uint256 deadline);

    error ZeroAddress();
    error ZeroPrice();
    error NotTokenOwner(uint256 tokenId, address caller);
    error AlreadyListed(uint256 tokenId);
    error NotListed(uint256 tokenId);
    error NotSeller(uint256 tokenId, address caller);
    error PriceMismatch(uint256 expected, uint256 actual);
    error CannotBuyOwnNFT();
    error NotWhitelisted(address buyer);
    error NotAdmin();
    error NotNFT();
    error UnsolicitedNFT();

    /// @param _token 支付代币，必须实现 EIP-2612 `permit`。
    /// @param _nft 被交易的 NFT。
    /// @param _admin 白名单管理员。
    /// @param _merkleRoot 白名单默克尔根。
    constructor(IERC20Permit _token, IERC721 _nft, address _admin, bytes32 _merkleRoot) {
        if (address(_token) == address(0) || address(_nft) == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }

        token = IERC20(address(_token));
        nft = _nft;
        admin = _admin;
        merkleRoot = _merkleRoot;

        emit MerkleRootUpdated(bytes32(0), _merkleRoot);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ---------------------------------------------------------------
    // 白名单（Merkle Tree）
    // ---------------------------------------------------------------

    /// @notice 更新白名单默克尔根。
    function setMerkleRoot(bytes32 _merkleRoot) external onlyAdmin {
        emit MerkleRootUpdated(merkleRoot, _merkleRoot);
        merkleRoot = _merkleRoot;
    }

    /// @notice 查询 user 是否在白名单中。
    function isWhitelisted(address user, bytes32[] calldata merkleProof) external view returns (bool) {
        return _verifyWhitelist(user, merkleProof);
    }

    /// @dev 叶子 = keccak256(abi.encodePacked(user))，用 MerkleProof 校验。
    function _verifyWhitelist(address user, bytes32[] calldata merkleProof) private view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user));
        return MerkleProof.verifyCalldata(merkleProof, merkleRoot, leaf);
    }

    // ---------------------------------------------------------------
    // 上架 / 购买 / 下架
    // ---------------------------------------------------------------

    /// @notice 上架 NFT，price 为购买该 NFT 需要支付的 TOKEN 数量。
    /// @dev 调用前需要先对 NFT 合约 approve 本市场；NFT 会转入本合约托管。
    function list(uint256 tokenId, uint256 price) public {
        if (price == 0) revert ZeroPrice();
        if (listings[tokenId].seller != address(0)) revert AlreadyListed(tokenId);
        if (nft.ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner(tokenId, msg.sender);
        }

        listings[tokenId] = Listing({seller: msg.sender, price: price});

        // 先更新状态，再把 NFT 托管进市场。
        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice 白名单用户购买 NFT。
    /// @param tokenId 要购买的 NFT ID。
    /// @param amount 支付的 TOKEN 数量，必须与上架价格一致。
    /// @param merkleProof 证明 msg.sender 在白名单中的 Merkle Proof。
    /// @dev 买家需要先让市场获得足够的 TOKEN 额度：
    ///      - 传统方式：`token.approve(address(market), amount)`；
    ///      - 离线签名：`permitPrePay(...)`，或通过 `multicall` 与本次购买打包。
    function buyNFT(uint256 tokenId, uint256 amount, bytes32[] calldata merkleProof) external {
        if (!_verifyWhitelist(msg.sender, merkleProof)) revert NotWhitelisted(msg.sender);

        _buy(msg.sender, tokenId, amount);
    }

    /// @notice 下架自己上架的 NFT，并取回托管的 NFT。
    function delist(uint256 tokenId) public {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (listing.seller != msg.sender) revert NotSeller(tokenId, msg.sender);

        delete listings[tokenId];
        nft.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Delisted(tokenId, msg.sender);
    }

    // ---------------------------------------------------------------
    // ERC20Permit 预授权
    // ---------------------------------------------------------------

    /// @notice 代替 owner 调用支付代币的 `permit`，把本市场设为 spender。
    /// @dev owner 离线签名 EIP-2612 Permit 后，任意地址（包括 owner 自己）都可以提交；
    ///      签名里的 spender 必须是本市场地址，value 至少为购买价格。
    ///      用 try/catch 包裹：如果 permit 已经被别人抢先提交（nonce 被消耗），
    ///      这里会失败但不会回滚整笔交易，后续 `buyNFT` 只要额度已生效仍可成功。
    /// @param owner 代币持有人，也是离线签名者。
    /// @param amount 授权的 TOKEN 数量。
    /// @param deadline 签名截止时间戳（秒）。
    /// @param v ECDSA 签名参数。
    /// @param r ECDSA 签名参数。
    /// @param s ECDSA 签名参数。
    function permitPrePay(
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (owner == address(0)) revert ZeroAddress();

        try IERC20Permit(address(token)).permit(owner, address(this), amount, deadline, v, r, s) {
            emit PermitPrePaid(owner, amount, deadline);
        } catch {}
    }

    // ---------------------------------------------------------------
    // Multicall（基于 delegatecall）
    // ---------------------------------------------------------------

    /// @notice 把多个对本合约的调用打包进一笔交易。
    /// @dev 使用 `delegatecall` 在**本合约的上下文**中依次执行每个 calldata：
    ///      msg.sender、address(this)、存储都保持不变，
    ///      所以 `permitPrePay` 里 `address(this)` 仍然是市场地址，
    ///      `buyNFT` 里的 msg.sender 仍然是原始调用者。
    ///      典型用法：
    ///        multicall([
    ///            abi.encodeCall(market.permitPrePay, (buyer, price, deadline, v, r, s)),
    ///            abi.encodeCall(market.buyNFT, (tokenId, price, proof))
    ///        ])
    ///      任一子调用失败都会冒泡 revert（整批回滚）。
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);

        for (uint256 i = 0; i < data.length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly ("memory-safe") {
                    // 原样抛出子调用的 revert 数据。
                    revert(add(result, 32), mload(result))
                }
            }
            results[i] = result;
        }
    }

    // ---------------------------------------------------------------
    // 内部逻辑与回调
    // ---------------------------------------------------------------

    /// @dev buyNFT 的购买逻辑，check-effects-interactions。
    function _buy(address buyer, uint256 tokenId, uint256 amount) private {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (buyer == listing.seller) revert CannotBuyOwnNFT();
        if (amount != listing.price) revert PriceMismatch(listing.price, amount);

        // 先清除上架状态，再做外部调用。
        delete listings[tokenId];

        // TOKEN 由买家直接转给卖家，本合约不托管 ERC20。
        token.safeTransferFrom(buyer, listing.seller, amount);

        // 把托管的 NFT 转给买家。
        nft.safeTransferFrom(address(this), buyer, tokenId);

        emit Bought(tokenId, buyer, listing.seller, amount);
    }

    /// @notice NFT safeTransferFrom 到本合约时的回调。
    /// @dev 只接受 list() 过程中由本市场自己发起的托管转账，
    ///      防止别人直接把 NFT 转进来卡死。
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata /* data */
    ) external view override returns (bytes4) {
        if (msg.sender != address(nft)) revert NotNFT();
        if (operator != address(this) || listings[tokenId].seller != from) {
            revert UnsolicitedNFT();
        }

        return IERC721Receiver.onERC721Received.selector;
    }
}
