// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {CalledToken} from "../src/CalledToken.sol";
import {MyERC721} from "../src/MyERC721.sol";
import {NFTMarket} from "../src/NFTMarket.sol";

contract NFTMarketTest is Test {
    CalledToken public token;
    MyERC721 public nft;
    NFTMarket public market;

    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public outsider = makeAddr("outsider");

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant PRICE = 100e18;
    uint256 internal constant USER_BALANCE = 1_000e18;
    string internal constant TOKEN_URI = "ipfs://test-token";

    function setUp() public {
        token = new CalledToken("Called Token", "CALL", 1_000_000e18);
        nft = new MyERC721();
        market = new NFTMarket(token, nft);

        // 给买卖双方发测试用的 TOKEN
        token.transfer(seller, USER_BALANCE);
        token.transfer(buyer, USER_BALANCE);

        // MyERC721 的 tokenId 从 1 开始，先给 seller 铸造一枚
        nft.mint(seller, TOKEN_URI);
    }

    // ---------------------------------------------------------------
    // 辅助函数
    // ---------------------------------------------------------------

    /// @dev seller 授权并上架 tokenId，价格为 PRICE。
    function _list() internal {
        vm.startPrank(seller);
        nft.approve(address(market), TOKEN_ID);
        market.list(TOKEN_ID, PRICE);
        vm.stopPrank();
    }

    function _assertListingCleared() internal view {
        (address listedSeller, uint256 listedPrice) = market.listings(TOKEN_ID);
        assertEq(listedSeller, address(0), "listing seller should be cleared");
        assertEq(listedPrice, 0, "listing price should be cleared");
    }

    // ---------------------------------------------------------------
    // list
    // ---------------------------------------------------------------

    function test_ListTransfersNFTToMarket() public {
        _list();

        // 上架采用托管模式，NFT 转到市场合约
        assertEq(nft.ownerOf(TOKEN_ID), address(market));

        (address listedSeller, uint256 listedPrice) = market.listings(TOKEN_ID);
        assertEq(listedSeller, seller);
        assertEq(listedPrice, PRICE);

        // tokenURI 不受影响
        assertEq(nft.tokenURI(TOKEN_ID), TOKEN_URI);
    }

    function test_ListEmitsEvent() public {
        vm.startPrank(seller);
        nft.approve(address(market), TOKEN_ID);

        vm.expectEmit(true, true, false, true, address(market));
        emit NFTMarket.Listed(TOKEN_ID, seller, PRICE);
        market.list(TOKEN_ID, PRICE);

        vm.stopPrank();
    }

    function test_ListRevertsOnZeroPrice() public {
        vm.prank(seller);
        vm.expectRevert(NFTMarket.ZeroPrice.selector);
        market.list(TOKEN_ID, 0);
    }

    function test_ListRevertsWhenCallerIsNotOwner() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarket.NotTokenOwner.selector, TOKEN_ID, outsider)
        );
        market.list(TOKEN_ID, PRICE);
    }

    function test_ListRevertsWhenAlreadyListed() public {
        _list();

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarket.AlreadyListed.selector, TOKEN_ID)
        );
        market.list(TOKEN_ID, PRICE);
    }

    // ---------------------------------------------------------------
    // onERC721Received
    // ---------------------------------------------------------------

    function test_DirectSafeTransferToMarketReverts() public {
        // 没有先 list()，直接把 NFT safeTransfer 到市场会被拒绝，避免卡死
        vm.prank(seller);
        vm.expectRevert(NFTMarket.UnsolicitedNFT.selector);
        nft.safeTransferFrom(seller, address(market), TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    function test_OnERC721ReceivedRevertsForNonNFTCaller() public {
        vm.prank(outsider);
        vm.expectRevert(NFTMarket.NotNFT.selector);
        market.onERC721Received(outsider, seller, TOKEN_ID, "");
    }

    function test_OnERC721ReceivedRevertsForUnsolicitedTransfer() public {
        // 冒充 NFT 合约调用，但 operator 不是市场
        vm.prank(address(nft));
        vm.expectRevert(NFTMarket.UnsolicitedNFT.selector);
        market.onERC721Received(outsider, seller, TOKEN_ID, "");
    }

    // ---------------------------------------------------------------
    // buyNFT（approve + transferFrom）
    // ---------------------------------------------------------------

    function test_BuyNFTTransfersTokenToSellerAndNFTToBuyer() public {
        _list();

        uint256 sellerBefore = token.balanceOf(seller);
        uint256 buyerBefore = token.balanceOf(buyer);

        vm.startPrank(buyer);
        token.approve(address(market), PRICE);
        market.buyNFT(TOKEN_ID, PRICE);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(token.balanceOf(seller), sellerBefore + PRICE);
        assertEq(token.balanceOf(buyer), buyerBefore - PRICE);
        // 市场不托管 ERC20
        assertEq(token.balanceOf(address(market)), 0);
        _assertListingCleared();
    }

    function test_BuyNFTEmitsEvent() public {
        _list();

        vm.startPrank(buyer);
        token.approve(address(market), PRICE);

        vm.expectEmit(true, true, true, true, address(market));
        emit NFTMarket.Bought(TOKEN_ID, buyer, seller, PRICE);
        market.buyNFT(TOKEN_ID, PRICE);

        vm.stopPrank();
    }

    function test_BuyNFTRevertsOnPriceMismatch() public {
        _list();

        vm.startPrank(buyer);
        token.approve(address(market), PRICE);

        vm.expectRevert(
            abi.encodeWithSelector(NFTMarket.PriceMismatch.selector, PRICE, PRICE - 1)
        );
        market.buyNFT(TOKEN_ID, PRICE - 1);

        vm.stopPrank();
    }

    function test_BuyNFTRevertsWhenNotListed() public {
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarket.NotListed.selector, TOKEN_ID)
        );
        market.buyNFT(TOKEN_ID, PRICE);
    }

    function test_BuyNFTRevertsWhenSellerBuysOwnNFT() public {
        _list();

        vm.prank(seller);
        vm.expectRevert(NFTMarket.CannotBuyOwnNFT.selector);
        market.buyNFT(TOKEN_ID, PRICE);
    }

    function test_BuyNFTRevertsWithoutTokenApproval() public {
        _list();

        vm.prank(buyer);
        // OZ ERC20 的 ERC20InsufficientAllowance
        vm.expectRevert();
        market.buyNFT(TOKEN_ID, PRICE);
    }

    // ---------------------------------------------------------------
    // transferAndCall 回调购买
    // ---------------------------------------------------------------

    function test_TransferAndCallBuysNFTWithoutApproval() public {
        _list();

        uint256 sellerBefore = token.balanceOf(seller);
        uint256 buyerBefore = token.balanceOf(buyer);

        // 不需要 approve，直接把 TOKEN 转给市场并附带 tokenId
        vm.prank(buyer);
        token.transferAndCall(address(market), PRICE, abi.encode(TOKEN_ID));

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(token.balanceOf(seller), sellerBefore + PRICE);
        assertEq(token.balanceOf(buyer), buyerBefore - PRICE);
        // 市场把收到的 TOKEN 转发给卖家后余额归零
        assertEq(token.balanceOf(address(market)), 0);
        _assertListingCleared();
    }

    function test_TransferAndCallEmitsBought() public {
        _list();

        vm.prank(buyer);
        vm.expectEmit(true, true, true, true, address(market));
        emit NFTMarket.Bought(TOKEN_ID, buyer, seller, PRICE);
        token.transferAndCall(address(market), PRICE, abi.encode(TOKEN_ID));
    }

    // 回调内部的 revert 会被 transferAndCall 捕获，最终抛出 TokensReceiptRejected

    function test_TransferAndCallRevertsWhenNotListed() public {
        vm.prank(buyer);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        token.transferAndCall(address(market), PRICE, abi.encode(TOKEN_ID));
    }

    function test_TransferAndCallRevertsOnPriceMismatch() public {
        _list();

        uint256 buyerBefore = token.balanceOf(buyer);

        vm.prank(buyer);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        token.transferAndCall(address(market), PRICE - 1, abi.encode(TOKEN_ID));

        // 整笔交易回滚：TOKEN 和 NFT 都不会动
        assertEq(token.balanceOf(buyer), buyerBefore);
        assertEq(nft.ownerOf(TOKEN_ID), address(market));
    }

    function test_TransferAndCallRevertsOnInvalidData() public {
        _list();

        vm.prank(buyer);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        // data 为空，无法解码 tokenId
        token.transferAndCall(address(market), PRICE, "");
    }

    function test_TransferAndCallRevertsWhenSellerBuysOwnNFT() public {
        _list();

        vm.prank(seller);
        vm.expectRevert(CalledToken.TokensReceiptRejected.selector);
        token.transferAndCall(address(market), PRICE, abi.encode(TOKEN_ID));
    }

    // ---------------------------------------------------------------
    // onTokensReceived 直接调用
    // ---------------------------------------------------------------

    function test_OnTokensReceivedRevertsForNonTokenCaller() public {
        vm.prank(outsider);
        vm.expectRevert(NFTMarket.NotToken.selector);
        market.onTokensReceived(outsider, buyer, PRICE, abi.encode(TOKEN_ID));
    }

    function test_OnTokensReceivedRevertsOnInvalidData() public {
        vm.prank(address(token));
        vm.expectRevert(NFTMarket.InvalidData.selector);
        market.onTokensReceived(buyer, buyer, PRICE, "");
    }

    // ---------------------------------------------------------------
    // delist
    // ---------------------------------------------------------------

    function test_DelistReturnsNFTToSeller() public {
        _list();

        vm.prank(seller);
        market.delist(TOKEN_ID);

        assertEq(nft.ownerOf(TOKEN_ID), seller);
        _assertListingCleared();
    }

    function test_DelistEmitsEvent() public {
        _list();

        vm.prank(seller);
        vm.expectEmit(true, true, false, true, address(market));
        emit NFTMarket.Delisted(TOKEN_ID, seller);
        market.delist(TOKEN_ID);
    }

    function test_DelistRevertsForNonSeller() public {
        _list();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarket.NotSeller.selector, TOKEN_ID, outsider)
        );
        market.delist(TOKEN_ID);
    }

    function test_DelistRevertsWhenNotListed() public {
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarket.NotListed.selector, TOKEN_ID)
        );
        market.delist(TOKEN_ID);
    }

    function test_CannotBuyAfterDelist() public {
        _list();

        vm.prank(seller);
        market.delist(TOKEN_ID);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(NFTMarket.NotListed.selector, TOKEN_ID)
        );
        market.buyNFT(TOKEN_ID, PRICE);
    }

    // ---------------------------------------------------------------
    // 构造参数
    // ---------------------------------------------------------------

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(NFTMarket.ZeroAddress.selector);
        new NFTMarket(CalledToken(address(0)), nft);

        vm.expectRevert(NFTMarket.ZeroAddress.selector);
        new NFTMarket(token, IERC721(address(0)));
    }
}
