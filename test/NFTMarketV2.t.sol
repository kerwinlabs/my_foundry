// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UnsafeUpgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";

import {CalledToken} from "../src/CalledToken.sol";
import {MyERC721} from "../src/MyERC721.sol";
import {NFTMarketV1} from "../src/NFTMarketV1.sol";
import {NFTMarketV2} from "../src/NFTMarketV2.sol";

/// @notice NFTMarketV2 测试：
///         1. 用透明代理部署 NFTMarketV1，再升级到 NFTMarketV2（UnsafeUpgrades 只部署/升级，不做 FFI 校验）；
///         2. 模拟卖家离线对 (tokenId, price) 做 EIP-712 签名；
///         3. 买家把签名传给 buyWithSellerSignature 完成购买。
contract NFTMarketV2Test is Test {
    CalledToken public token;
    MyERC721 public nft;
    NFTMarketV1 public v1;
    NFTMarketV2 public market;
    address public proxy;

    /// @notice 卖家私钥，测试里用它模拟链下签名。
    uint256 internal constant SELLER_PK = 0x5E11E2;
    address public seller;

    address public buyer;
    address public outsider;
    address public admin;

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant PRICE = 100e18;
    uint256 internal constant USER_BALANCE = 1_000e18;
    string internal constant TOKEN_URI = "ipfs://test-token";

    function setUp() public {
        seller = vm.addr(SELLER_PK);
        buyer = makeAddr("buyer");
        outsider = makeAddr("outsider");
        admin = makeAddr("admin");

        token = new CalledToken("Called Token", "CALL", 1_000_000e18);
        nft = new MyERC721();

        token.transfer(seller, USER_BALANCE);
        token.transfer(buyer, USER_BALANCE);
        nft.mint(seller, TOKEN_URI);

        // 1. 部署 V1 实现 + 透明代理（ProxyAdmin 的 owner 是测试合约）
        v1 = new NFTMarketV1();
        proxy = UnsafeUpgrades.deployTransparentProxy(
            address(v1),
            address(this),
            abi.encodeCall(
                NFTMarketV1.initialize,
                (address(token), address(nft), admin)
            )
        );

        // 2. 升级到 V2
        NFTMarketV2 v2 = new NFTMarketV2();
        UnsafeUpgrades.upgradeProxy(proxy, address(v2), "");

        // 代理地址才是对外的市场地址
        market = NFTMarketV2(proxy);
    }

    // ---------------------------------------------------------------
    // 辅助函数
    // ---------------------------------------------------------------

    /// @dev 计算卖家签名上架的 EIP-712 digest：SellNFT(uint256 tokenId,uint256 price)
    function _sellDigest(uint256 tokenId, uint256 price) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(market.SELL_NFT_TYPEHASH(), tokenId, price)
        );
        return keccak256(
            abi.encodePacked("\x19\x01", market.DOMAIN_SEPARATOR(), structHash)
        );
    }

    /// @dev 模拟卖家在链下对 (tokenId, price) 签名。
    function _signSell(
        uint256 sellerPk,
        uint256 tokenId,
        uint256 price
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        (v, r, s) = vm.sign(sellerPk, _sellDigest(tokenId, price));
    }

    /// @dev 卖家一次性把 NFT 授权给市场（对应需求里的 setApprovalForAll）。
    function _approveAll() internal {
        vm.prank(seller);
        nft.setApprovalForAll(address(market), true);
    }

    /// @dev 买家 approve TOKEN 后带着卖家签名购买。
    function _buyWithSignature(uint8 v, bytes32 r, bytes32 s) internal {
        vm.startPrank(buyer);
        token.approve(address(market), PRICE);
        market.buyWithSellerSignature(TOKEN_ID, PRICE, v, r, s);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // 透明代理 + 升级
    // ---------------------------------------------------------------

    function test_UpgradePreservesV1State() public {
        // setUp 里已经完成 V1 -> V2 升级，初始化数据仍然保存在代理里
        assertEq(address(market.token()), address(token));
        assertEq(address(market.nft()), address(nft));
        assertEq(market.admin(), admin);
        assertEq(market.permitNonces(buyer), 0);
    }

    function test_UpgradePreservesEscrowListing() public {
        // 单独部署一套 V1 代理，先走 V1 的 list() 托管上架，再升级到 V2
        NFTMarketV1 impl1 = new NFTMarketV1();
        address p = UnsafeUpgrades.deployTransparentProxy(
            address(impl1),
            address(this),
            abi.encodeCall(
                NFTMarketV1.initialize,
                (address(token), address(nft), admin)
            )
        );
        NFTMarketV1 m1 = NFTMarketV1(p);

        vm.startPrank(seller);
        nft.approve(p, TOKEN_ID);
        m1.list(TOKEN_ID, PRICE);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), p);

        UnsafeUpgrades.upgradeProxy(p, address(new NFTMarketV2()), "");

        NFTMarketV2 m2 = NFTMarketV2(p);
        (address listedSeller, uint256 listedPrice) = m2.listings(TOKEN_ID);
        assertEq(listedSeller, seller, "listing seller should survive upgrade");
        assertEq(listedPrice, PRICE, "listing price should survive upgrade");
        assertEq(nft.ownerOf(TOKEN_ID), p);
    }

    function test_ProxyAdminCannotCallImplementationFunctions() public {
        address proxyAdmin = UnsafeUpgrades.getAdminAddress(proxy);

        // 透明代理：管理员只能调用 upgradeToAndCall，调用实现合约函数会被拒绝
        vm.prank(proxyAdmin);
        vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
        market.admin();
    }

    // ---------------------------------------------------------------
    // buyWithSellerSignature
    // ---------------------------------------------------------------

    function test_BuyWithSellerSignature() public {
        _approveAll();

        // 卖家链下签名：内容只有 tokenId 和 price
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);
        bytes32 digest = _sellDigest(TOKEN_ID, PRICE);

        uint256 sellerBefore = token.balanceOf(seller);
        uint256 buyerBefore = token.balanceOf(buyer);

        // 买家带着签名购买
        _buyWithSignature(v, r, s);

        assertEq(nft.ownerOf(TOKEN_ID), buyer, "NFT should belong to buyer");
        assertEq(token.balanceOf(seller), sellerBefore + PRICE, "seller should receive TOKEN");
        assertEq(token.balanceOf(buyer), buyerBefore - PRICE, "buyer should pay TOKEN");
        assertEq(token.balanceOf(address(market)), 0, "market should not hold TOKEN");
        assertTrue(market.usedSellSignatures(digest), "signature should be marked used");
        // one-time setApprovalForAll 依然有效，卖家后续其他 NFT 无需再次授权
        assertTrue(nft.isApprovedForAll(seller, address(market)));
    }

    function test_BuyWithSellerSignatureEmitsEvent() public {
        _approveAll();
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);
        bytes32 digest = _sellDigest(TOKEN_ID, PRICE);

        vm.startPrank(buyer);
        token.approve(address(market), PRICE);

        vm.expectEmit(true, true, true, true, address(market));
        emit NFTMarketV2.BoughtWithSellerSignature(TOKEN_ID, buyer, seller, PRICE, digest);
        market.buyWithSellerSignature(TOKEN_ID, PRICE, v, r, s);

        vm.stopPrank();
    }

    function test_SignatureCannotBeReused() public {
        _approveAll();
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);
        bytes32 digest = _sellDigest(TOKEN_ID, PRICE);

        _buyWithSignature(v, r, s);

        // 买家把 NFT 转回卖家，让「卖家仍是 owner」这一条件重新成立
        vm.prank(buyer);
        nft.safeTransferFrom(buyer, seller, TOKEN_ID);

        // 同一份签名仍应被拒绝，因为 digest 已标记为使用过
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarketV2.SignatureAlreadyUsed.selector, digest)
        );
        market.buyWithSellerSignature(TOKEN_ID, PRICE, v, r, s);
    }

    function test_RevertsWhenSellerHasNotApprovedMarket() public {
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarketV2.SellerNotApproved.selector, seller)
        );
        market.buyWithSellerSignature(TOKEN_ID, PRICE, v, r, s);
    }

    function test_RevertsWhenPriceDiffersFromSignature() public {
        _approveAll();
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);

        // 买家擅自改价：digest 变化，恢复出的地址不再是卖家
        vm.prank(buyer);
        vm.expectRevert();
        market.buyWithSellerSignature(TOKEN_ID, PRICE + 1, v, r, s);
    }

    function test_RevertsWhenSellerIsBuyer() public {
        _approveAll();
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);

        vm.prank(seller);
        vm.expectRevert(NFTMarketV1.CannotBuyOwnNFT.selector);
        market.buyWithSellerSignature(TOKEN_ID, PRICE, v, r, s);
    }

    function test_RevertsWhenPriceIsZero() public {
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, 0);

        vm.prank(buyer);
        vm.expectRevert(NFTMarketV1.ZeroPrice.selector);
        market.buyWithSellerSignature(TOKEN_ID, 0, v, r, s);
    }

    function test_RevertsWhenSellerNoLongerOwnsNFT() public {
        // 卖家先把 NFT 转走，再用旧签名购买
        vm.prank(seller);
        nft.safeTransferFrom(seller, outsider, TOKEN_ID);

        _approveAll();
        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NFTMarketV2.NotNFTOwnerForSale.selector,
                TOKEN_ID,
                seller
            )
        );
        market.buyWithSellerSignature(TOKEN_ID, PRICE, v, r, s);
    }

    function test_SingleTokenApproveAlsoWorks() public {
        // 需求用 setApprovalForAll，这里顺带验证单个 approve 也兼容
        vm.prank(seller);
        nft.approve(address(market), TOKEN_ID);

        (uint8 v, bytes32 r, bytes32 s) = _signSell(SELLER_PK, TOKEN_ID, PRICE);
        _buyWithSignature(v, r, s);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
    }
}
