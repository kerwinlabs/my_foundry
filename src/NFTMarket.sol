// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {CalledToken, ITokensReceiver} from "./CalledToken.sol";

// ===========================================================================
// 支付方案对比（纯 ERC20 版本保留为注释，方便对照）
// ---------------------------------------------------------------------------
// 方案 A（当前启用）：CalledToken
//   CalledToken 本身是标准 ERC20，所以 approve + buyNFT 依然可用；
//   在此基础上额外支持 transferAndCall：
//   买家调用 Token.transferAndCall(market, price, abi.encode(tokenId))，
//   Token 先把钱转到市场，再回调 market.onTokensReceived 完成购买，无需 approve。
//
// 方案 B（纯 ERC20，已注释）：
//   只有 approve + buyNFT 一条路径：
//   买家先 Token.approve(market, price)，再调用 market.buyNFT(tokenId, price)，
//   由市场用 transferFrom 把钱从买家直接转给卖家。
//   如果换成 USDT 这类返回值不规范的代币，需要使用 SafeERC20。
//
// 两种方案的共同点：NFT 都在 list() 时托管到市场合约。
// ===========================================================================

// 方案 B 需要的 import：
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NFTMarket
/// @notice 使用 CalledToken 作为支付代币买卖 MyERC721 的简单市场。
///
///         上架流程：
///         1. NFT 持有者先调用 NFT.approve(address(market), tokenId) 授权；
///         2. 调用 list(tokenId, price) 上架，NFT 会转入本合约托管。
///
///         购买流程（二选一）：
///         1. approve + buyNFT（纯 ERC20 也同样支持）：
///            买家先调用 Token.approve(address(market), price)，再调用 buyNFT(tokenId, amount)；
///         2. transferAndCall 直接购买（CalledToken 专属）：
///            买家调用 Token.transferAndCall(address(market), price, abi.encode(tokenId))，
///            Token 合约会在转账后回调本合约的 onTokensReceived 完成购买，无需 approve。
///
///         卖家也可以调用 delist(tokenId) 下架并取回 NFT。
contract NFTMarket is ITokensReceiver, IERC721Receiver {
    // 方案 B（纯 ERC20）的声明：
    // using SafeERC20 for IERC20;
    // IERC20 public immutable token;

    /// @notice 支付代币（CalledToken）。
    CalledToken public immutable token;

    /// @notice 交易的 NFT（MyERC721）。
    IERC721 public immutable nft;

    /// @notice 上架信息。
    struct Listing {
        address seller;
        uint256 price;
    }

    /// @notice tokenId => 上架信息；seller 为零地址表示未上架。
    mapping(uint256 => Listing) public listings;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Bought(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 price
    );
    event Delisted(uint256 indexed tokenId, address indexed seller);

    error ZeroAddress();
    error ZeroPrice();
    error NotTokenOwner(uint256 tokenId, address caller);
    error AlreadyListed(uint256 tokenId);
    error NotListed(uint256 tokenId);
    error NotSeller(uint256 tokenId, address caller);
    error PriceMismatch(uint256 expected, uint256 actual);
    error CannotBuyOwnNFT();
    error NotToken();
    error InvalidData();
    error NotNFT();
    error UnsolicitedNFT();

    constructor(CalledToken _token, IERC721 _nft) {
        if (address(_token) == address(0) || address(_nft) == address(0)) {
            revert ZeroAddress();
        }
        token = _token;
        nft = _nft;
    }

    // 方案 B（纯 ERC20）的构造函数：
    // constructor(IERC20 _token, IERC721 _nft) {
    //     if (address(_token) == address(0) || address(_nft) == address(0)) {
    //         revert ZeroAddress();
    //     }
    //     token = _token;
    //     nft = _nft;
    // }

    /// @dev 只允许绑定的 CalledToken 合约调用回调，避免伪造购买。
    modifier onlyToken() {
        if (msg.sender != address(token)) revert NotToken();
        _;
    }

    /// @notice 上架 NFT，price 为购买该 NFT 需要支付的 TOKEN 数量。
    /// @dev 调用前需要先对 NFT 合约 approve 本市场；NFT 会转入本合约托管。
    function list(uint256 tokenId, uint256 price) public {
        if (price == 0) revert ZeroPrice();
        if (listings[tokenId].seller != address(0)) revert AlreadyListed(tokenId);
        if (nft.ownerOf(tokenId) != msg.sender) {
            revert NotTokenOwner(tokenId, msg.sender);
        }

        listings[tokenId] = Listing({seller: msg.sender, price: price});

        // 托管 NFT：先完成状态更新，再用 safeTransferFrom 转入合约。
        // safeTransferFrom 会回调本合约的 onERC721Received，用于确认市场能接收 NFT。
        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice 购买已上架的 NFT（需要先 approve 本市场）。
    /// @param tokenId 要购买的 NFT ID。
    /// @param amount  支付的 TOKEN 数量，必须与上架价格一致。
    function buyNFT(uint256 tokenId, uint256 amount) public {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (msg.sender == listing.seller) revert CannotBuyOwnNFT();
        if (amount != listing.price) {
            revert PriceMismatch(listing.price, amount);
        }

        // checks-effects-interactions：先清除上架状态，再做外部调用。
        delete listings[tokenId];

        // TOKEN 由买家直接转给卖家，本合约不托管 ERC20。
        // 方案 A（CalledToken）：CalledToken 本身就是标准 ERC20，直接 transferFrom 即可。
        token.transferFrom(msg.sender, listing.seller, amount);
        // 方案 B（纯 ERC20）：如果换成 USDT 这类非标准代币，改用 SafeERC20：
        // token.safeTransferFrom(msg.sender, listing.seller, amount);

        // 把托管的 NFT 转给买家。
        nft.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Bought(tokenId, msg.sender, listing.seller, amount);
    }

    /// @notice CalledToken.transferAndCall 的回调，用 transferAndCall 直接购买 NFT。
    /// @dev 只有方案 A（CalledToken）需要这个函数；
    ///      方案 B（纯 ERC20）没有回调，买家只能先 approve 再调用 buyNFT。
    /// @param from   代币转出方，也就是买家。
    /// @param amount 转入本合约的 TOKEN 数量，必须与上架价格一致。
    /// @param data   abi.encode(tokenId)，用来指定要购买的 NFT。
    /// @dev 代币此时已经转入本合约；校验失败会 revert，整笔 transferAndCall 回滚。
    function onTokensReceived(
        address, /* operator */
        address from,
        uint256 amount,
        bytes calldata data
    )
        external
        onlyToken
        override
        returns (bytes4)
    {
        if (data.length != 32) revert InvalidData();
        uint256 tokenId = abi.decode(data, (uint256));

        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (from == listing.seller) revert CannotBuyOwnNFT();
        if (amount != listing.price) {
            revert PriceMismatch(listing.price, amount);
        }

        delete listings[tokenId];

        // 代币已在本合约，转给卖家；再把托管的 NFT 转给买家。
        token.transfer(listing.seller, amount);
        nft.safeTransferFrom(address(this), from, tokenId);

        emit Bought(tokenId, from, listing.seller, amount);

        return ITokensReceiver.onTokensReceived.selector;
    }

    /// @notice NFT safeTransferFrom 到本合约时的回调。
    /// @dev 只接受 list() 过程中、由本市场自己发起的托管转账：
    ///      - msg.sender 必须是绑定的 NFT 合约；
    ///      - operator 必须是本市场（说明是 list() 里调用的 safeTransferFrom）；
    ///      - tokenId 的上架记录必须已经属于 from（list() 先写记录、再转移 NFT）。
    ///      其他人直接把 NFT safeTransferFrom 到本合约会被拒绝，避免 NFT 卡死在市场里。
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

    /// @notice 下架自己上架的 NFT，并取回托管的 NFT。
    function delist(uint256 tokenId) public {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (listing.seller != msg.sender) revert NotSeller(tokenId, msg.sender);

        delete listings[tokenId];
        nft.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Delisted(tokenId, msg.sender);
    }
}
