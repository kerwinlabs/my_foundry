// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MyPermitToken} from "../src/MyPermitToken.sol";
import {MyERC721} from "../src/MyERC721.sol";
import {AirdopMerkleNFTMarket} from "../src/AirdopMerkleNFTMarket.sol";

/// @notice AirdopMerkleNFTMarket 的测试：
///         默克尔白名单、list/buyNFT/delist、permitPrePay 预授权、multicall 打包购买。
/// 运行：
///   forge test --match-path test/AirdopMerkleNFTMarket.t.sol -vv
contract AirdopMerkleNFTMarketTest is Test {
    MyPermitToken internal token;
    MyERC721 internal nft;
    AirdopMerkleNFTMarket internal market;

    address internal admin;
    address internal seller;
    address internal mallory;

    uint256 internal constant ALICE_KEY = 0xA11CE;
    uint256 internal constant BOB_KEY = 0xB0B;
    address internal alice;
    address internal bob;

    /// @dev 白名单树只有两个叶子：alice 和 bob。
    bytes32 internal aliceLeaf;
    bytes32 internal bobLeaf;
    bytes32 internal root;

    uint256 internal constant PRICE = 100 ether;
    uint256 internal constant NFT_ID = 1;
    string internal constant TOKEN_URI = "ipfs://nft/1";

    function setUp() public {
        admin = makeAddr("admin");
        seller = makeAddr("seller");
        mallory = makeAddr("mallory");
        alice = vm.addr(ALICE_KEY);
        bob = vm.addr(BOB_KEY);

        token = new MyPermitToken("Permit Bank Token", "PBT", 1_000_000 ether);
        nft = new MyERC721();

        // ---- 默克尔树：root = hash(leaf(alice), leaf(bob)) ----
        aliceLeaf = _leaf(alice);
        bobLeaf = _leaf(bob);
        root = _hashPair(aliceLeaf, bobLeaf);

        market = new AirdopMerkleNFTMarket(
            IERC20Permit(address(token)),
            IERC721(address(nft)),
            admin,
            root
        );

        // 分配支付代币
        token.transfer(alice, 10_000 ether);
        token.transfer(bob, 10_000 ether);

        // seller 铸造并上架 #1
        nft.mint(seller, TOKEN_URI);
        vm.startPrank(seller);
        nft.approve(address(market), NFT_ID);
        market.list(NFT_ID, PRICE);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // 辅助函数
    // ---------------------------------------------------------------

    function _leaf(address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user));
    }

    /// @dev 与 OZ MerkleProof 一致：排序后再哈希。
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev 两叶子树的 proof：alice 的 proof 是 bobLeaf，bob 的 proof 是 aliceLeaf。
    function _proofFor(address user) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        if (user == alice) {
            proof[0] = bobLeaf;
        } else if (user == bob) {
            proof[0] = aliceLeaf;
        } else {
            revert("user not in tree");
        }
    }

    function _approve(address user, uint256 amount) internal {
        vm.prank(user);
        token.approve(address(market), amount);
    }

    /// @dev EIP-2612 Permit 的 EIP-712 digest（spender = market）。
    function _permitDigest(address owner, uint256 value, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(market),
                value,
                token.nonces(owner),
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _signPermit(uint256 key, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        (v, r, s) = vm.sign(key, _permitDigest(owner, value, deadline));
    }

    // ---------------------------------------------------------------
    // 白名单
    // ---------------------------------------------------------------

    function test_IsWhitelisted() public view {
        assertTrue(market.isWhitelisted(alice, _proofFor(alice)));
        assertTrue(market.isWhitelisted(bob, _proofFor(bob)));
        assertFalse(market.isWhitelisted(mallory, new bytes32[](0)));
    }

    function test_WhitelistedBuyerCanBuy() public {
        _approve(alice, PRICE);
        bytes32[] memory proof = _proofFor(alice);

        vm.expectEmit(true, true, true, true, address(market));
        emit AirdopMerkleNFTMarket.Bought(NFT_ID, alice, seller, PRICE);

        vm.prank(alice);
        market.buyNFT(NFT_ID, PRICE, proof);

        assertEq(nft.ownerOf(NFT_ID), alice);
        assertEq(token.balanceOf(seller), PRICE);
        assertEq(token.balanceOf(alice), 10_000 ether - PRICE);

        (address listingSeller, ) = market.listings(NFT_ID);
        assertEq(listingSeller, address(0), "listing should be cleared");
    }

    function test_NonWhitelistedCannotBuy() public {
        _approve(mallory, PRICE);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(AirdopMerkleNFTMarket.NotWhitelisted.selector, mallory));
        market.buyNFT(NFT_ID, PRICE, new bytes32[](0));
    }

    function test_NonAdminCannotSetMerkleRoot() public {
        vm.prank(mallory);
        vm.expectRevert(AirdopMerkleNFTMarket.NotAdmin.selector);
        market.setMerkleRoot(bytes32(uint256(1)));
    }

    function test_AdminCanUpdateWhitelistAndBuy() public {
        // 新的单叶子树：only mallory，proof 为空数组
        bytes32 newRoot = _leaf(mallory);
        vm.prank(admin);
        market.setMerkleRoot(newRoot);

        assertEq(market.merkleRoot(), newRoot);
        assertFalse(market.isWhitelisted(alice, _proofFor(alice)), "old whitelist should be invalid");

        token.transfer(mallory, PRICE);
        _approve(mallory, PRICE);

        vm.prank(mallory);
        market.buyNFT(NFT_ID, PRICE, new bytes32[](0));

        assertEq(nft.ownerOf(NFT_ID), mallory);
    }

    // ---------------------------------------------------------------
    // 上架 / 购买校验 / 下架
    // ---------------------------------------------------------------

    function test_ListZeroPriceReverts() public {
        vm.prank(seller);
        vm.expectRevert(AirdopMerkleNFTMarket.ZeroPrice.selector);
        market.list(NFT_ID, 0);
    }

    function test_ListAlreadyListedReverts() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AirdopMerkleNFTMarket.AlreadyListed.selector, NFT_ID));
        market.list(NFT_ID, PRICE);
    }

    function test_ListByNonOwnerReverts() public {
        nft.mint(seller, "ipfs://nft/2");

        vm.prank(mallory);
        vm.expectRevert(
            abi.encodeWithSelector(AirdopMerkleNFTMarket.NotTokenOwner.selector, uint256(2), mallory)
        );
        market.list(2, PRICE);
    }

    function test_BuyWrongPriceReverts() public {
        _approve(alice, PRICE);
        bytes32[] memory proof = _proofFor(alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AirdopMerkleNFTMarket.PriceMismatch.selector, PRICE, PRICE - 1)
        );
        market.buyNFT(NFT_ID, PRICE - 1, proof);
    }

    function test_CannotBuyOwnNFT() public {
        // alice 自己上架 #2 后再尝试购买
        nft.mint(alice, "ipfs://nft/2");
        vm.startPrank(alice);
        nft.approve(address(market), 2);
        market.list(2, PRICE);
        vm.stopPrank();

        _approve(alice, PRICE);

        vm.prank(alice);
        vm.expectRevert(AirdopMerkleNFTMarket.CannotBuyOwnNFT.selector);
        market.buyNFT(2, PRICE, _proofFor(alice));
    }

    function test_DelistReturnsNFT() public {
        vm.expectEmit(true, true, false, true, address(market));
        emit AirdopMerkleNFTMarket.Delisted(NFT_ID, seller);

        vm.prank(seller);
        market.delist(NFT_ID);

        assertEq(nft.ownerOf(NFT_ID), seller);

        (address listingSeller, ) = market.listings(NFT_ID);
        assertEq(listingSeller, address(0));
    }

    function test_DelistByNonSellerReverts() public {
        vm.prank(mallory);
        vm.expectRevert(
            abi.encodeWithSelector(AirdopMerkleNFTMarket.NotSeller.selector, NFT_ID, mallory)
        );
        market.delist(NFT_ID);
    }

    function test_UnsolicitedNFTReverts() public {
        nft.mint(seller, "ipfs://nft/2");

        vm.startPrank(seller);
        nft.approve(address(market), 2);
        vm.expectRevert(AirdopMerkleNFTMarket.UnsolicitedNFT.selector);
        nft.safeTransferFrom(seller, address(market), 2);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // permitPrePay
    // ---------------------------------------------------------------

    function test_PermitPrePaySetsAllowance() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, alice, PRICE, deadline);

        vm.prank(alice);
        market.permitPrePay(alice, PRICE, deadline, v, r, s);

        assertEq(token.allowance(alice, address(market)), PRICE);
    }

    function test_PermitPrePayThenBuy() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, alice, PRICE, deadline);

        vm.prank(alice);
        market.permitPrePay(alice, PRICE, deadline, v, r, s);

        vm.prank(alice);
        market.buyNFT(NFT_ID, PRICE, _proofFor(alice));

        assertEq(nft.ownerOf(NFT_ID), alice);
    }

    /// @dev 签名无效时 permitPrePay 内部 try/catch 吞掉错误，不 revert，额度保持 0。
    function test_PermitPrePayInvalidSignatureDoesNotRevert() public {
        uint256 deadline = block.timestamp + 1 days;
        // 用 bob 的私钥签 alice 的 permit
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(BOB_KEY, alice, PRICE, deadline);

        vm.prank(alice);
        market.permitPrePay(alice, PRICE, deadline, v, r, s);

        assertEq(token.allowance(alice, address(market)), 0);
    }

    // ---------------------------------------------------------------
    // multicall（delegatecall）
    // ---------------------------------------------------------------

    function test_MulticallPermitAndBuy() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ALICE_KEY, alice, PRICE, deadline);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(market.permitPrePay, (alice, PRICE, deadline, v, r, s));
        calls[1] = abi.encodeCall(market.buyNFT, (NFT_ID, PRICE, _proofFor(alice)));

        vm.expectEmit(true, true, true, true, address(market));
        emit AirdopMerkleNFTMarket.Bought(NFT_ID, alice, seller, PRICE);

        vm.prank(alice);
        market.multicall(calls);

        assertEq(nft.ownerOf(NFT_ID), alice);
        assertEq(token.balanceOf(seller), PRICE);
        // permit 设的额度已经全部被 transferFrom 消耗
        assertEq(token.allowance(alice, address(market)), 0);
    }

    function test_MulticallBubblesRevert() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(market.buyNFT, (NFT_ID, PRICE, new bytes32[](0)));

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(AirdopMerkleNFTMarket.NotWhitelisted.selector, mallory));
        market.multicall(calls);
    }
}
