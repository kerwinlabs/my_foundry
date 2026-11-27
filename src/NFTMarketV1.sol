// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CalledToken, ITokensReceiver} from "./CalledToken.sol";

/// @title NFTMarketV1
/// @notice NFTMarket 的可升级版本（版本 1），部署在透明代理（TransparentUpgradeableProxy）之后。
///         功能与 NFTMarket 一致：list / buyNFT / permitBuy / transferAndCall / delist。
/// @dev 与不可升级版本的区别：
///      - 没有构造函数，改用 initialize 初始化；
///      - token / nft / admin 从 immutable 改为普通存储变量，这样升级后数据仍保存在代理合约中；
///      - EIP712 改为 EIP712Upgradeable。
///      构造函数据保留，仅用于锁定实现合约自身的初始化。
contract NFTMarketV1 is Initializable, EIP712Upgradeable, ITokensReceiver, IERC721Receiver {
    /// @notice 支付代币（CalledToken）。
    CalledToken public token;

    /// @notice 交易的 NFT（MyERC721）。
    IERC721 public nft;

    /// @notice 管理员地址，负责在后台离线签发 permitBuy 的白名单签名。
    address public admin;

    /// @notice permitBuy 的 EIP-712 结构体类型哈希。
    ///         PermitBuy(address buyer,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)
    bytes32 public constant PERMIT_BUY_TYPEHASH =
        keccak256("PermitBuy(address buyer,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)");

    /// @notice 买家 => 已使用的 permit 次数（签名 nonce），成功调用 permitBuy 后 +1，防止签名重放。
    mapping(address => uint256) public permitNonces;

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
    error PermitExpired(uint256 deadline);
    error InvalidPermitSigner(address signer);

    /// @dev 锁定实现合约自身的初始化；代理合约通过 initialize 初始化。
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化市场，只能通过代理调用一次。
    /// @param _token 支付代币（CalledToken）。
    /// @param _nft 被交易的 NFT（MyERC721）。
    /// @param _admin permitBuy 白名单签名的管理员地址。
    /// @dev EIP-712 domain：{ name: "NFTMarket", version: "1", chainId, verifyingContract: address(proxy) }。
    function initialize(address _token, address _nft, address _admin) public initializer {
        if (_token == address(0) || _nft == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }

        __EIP712_init("NFTMarket", "1");

        token = CalledToken(_token);
        nft = IERC721(_nft);
        admin = _admin;
    }

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
        nft.safeTransferFrom(msg.sender, address(this), tokenId);

        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice 购买已上架的 NFT（需要先 approve 本市场）。
    /// @param tokenId 要购买的 NFT ID。
    /// @param amount  支付的 TOKEN 数量，必须与上架价格一致。
    function buyNFT(uint256 tokenId, uint256 amount) public {
        _buy(msg.sender, tokenId, amount);
    }

    /// @notice 白名单购买：校验管理员离线签发的 EIP-712 PermitBuy 签名后完成购买。
    /// @dev 签名结构：PermitBuy(address buyer,uint256 tokenId,uint256 amount,uint256 nonce,uint256 deadline)。
    ///      买家仍需先调用 Token.approve(address(market), amount) 支付代币。
    function permitBuy(
        uint256 tokenId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired(deadline);

        address buyer = msg.sender;
        uint256 nonce = permitNonces[buyer];

        bytes32 structHash = keccak256(
            abi.encode(PERMIT_BUY_TYPEHASH, buyer, tokenId, amount, nonce, deadline)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);

        if (signer != admin) revert InvalidPermitSigner(signer);

        // checks-effects-interactions：先消耗 nonce，再进入购买流程，防止重放。
        permitNonces[buyer] = nonce + 1;

        _buy(buyer, tokenId, amount);
    }

    /// @notice 返回 EIP-712 domain separator，方便前端/测试构造签名。
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev buyNFT 与 permitBuy 共用的购买逻辑。
    function _buy(address buyer, uint256 tokenId, uint256 amount) private {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed(tokenId);
        if (buyer == listing.seller) revert CannotBuyOwnNFT();
        if (amount != listing.price) {
            revert PriceMismatch(listing.price, amount);
        }

        // checks-effects-interactions：先清除上架状态，再做外部调用。
        delete listings[tokenId];

        // TOKEN 由买家直接转给卖家，本合约不托管 ERC20。
        token.transferFrom(buyer, listing.seller, amount);

        // 把托管的 NFT 转给买家。
        nft.safeTransferFrom(address(this), buyer, tokenId);

        emit Bought(tokenId, buyer, listing.seller, amount);
    }

    /// @notice CalledToken.transferAndCall 的回调，用 transferAndCall 直接购买 NFT。
    /// @param from   代币转出方，也就是买家。
    /// @param amount 转入本合约的 TOKEN 数量，必须与上架价格一致。
    /// @param data   abi.encode(tokenId)，用来指定要购买的 NFT。
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
    /// @dev 只接受 list() 过程中、由本市场自己发起的托管转账。
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
