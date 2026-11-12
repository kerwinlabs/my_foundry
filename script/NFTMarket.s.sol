// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {CalledToken} from "../src/CalledToken.sol";
import {MyERC721} from "../src/MyERC721.sol";
import {NFTMarket} from "../src/NFTMarket.sol";

/// @notice 部署 NFTMarket 及其依赖：CalledToken（支付代币）和 MyERC721（被交易的 NFT）。
///         三个合约地址分别写入 deployments/<Name>_<chainId>.json。
/// 用法（需要环境变量 PRIVATE_KEY）:
///   PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/NFTMarket.s.sol:NFTMarketScript \
///     --rpc-url $RPC_URL --broadcast
contract NFTMarketScript is BaseScript {
    CalledToken public token;
    MyERC721 public nft;
    NFTMarket public market;

    function run() public broadcaster {
        // 1. 部署支付代币：初始供应量 1,000,000 个（decimals = 18），铸造给部署者
        token = new CalledToken("Market Token", "MTK", 1_000_000 * 10 ** 18);
        console.log("CalledToken deployed on %s", address(token));

        // 2. 部署 NFT
        nft = new MyERC721();
        console.log("MyERC721 deployed on %s", address(nft));

        // 3. 部署市场，绑定上面的代币和 NFT（构造函数会拒绝零地址）
        market = new NFTMarket(token, nft);
        console.log("NFTMarket deployed on %s", address(market));

        // 保存合约地址到本地
        saveContract("CalledToken", address(token));
        saveContract("MyERC721", address(nft));
        saveContract("NFTMarket", address(market));
    }
}
