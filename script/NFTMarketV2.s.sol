// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {NFTMarketV1} from "../src/NFTMarketV1.sol";
import {NFTMarketV2} from "../src/NFTMarketV2.sol";

/// @notice 使用透明代理（TransparentUpgradeableProxy）部署 NFTMarket：
///         1. 先把 NFTMarketV1 部署到透明代理后面并初始化；
///         2. 再把代理升级到 NFTMarketV2（新增卖家离线签名上架功能）。
///         ProxyAdmin 的 owner 为部署者，因此同一次脚本内可以直接执行升级。
///
///         依赖的 TOKEN 与 NFT 地址优先读环境变量 TOKEN_ADDRESS / NFT_ADDRESS，
///         没有则读取 deployments/CalledToken_<chainId>.json 与 MyERC721_<chainId>.json。
///         市场管理员默认是部署者，可用 MARKET_ADMIN 覆盖。
///
/// 用法（需要环境变量 PRIVATE_KEY）:
///   PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/NFTMarketV2.s.sol:NFTMarketV2Script \
///     --rpc-url $RPC_URL --broadcast --force
///
/// 注意：升级校验依赖 AST / storageLayout，请带 --force 或先 forge clean。
contract NFTMarketV2Script is BaseScript {
    address public proxy;
    address public v1Implementation;
    address public v2Implementation;
    NFTMarketV2 public market;

    function run() public broadcaster {
        address tokenAddress = _loadAddress("TOKEN_ADDRESS", "CalledToken");
        address nftAddress = _loadAddress("NFT_ADDRESS", "MyERC721");
        address marketAdmin = vm.envOr("MARKET_ADMIN", deployer);

        console.log("token        : %s", tokenAddress);
        console.log("nft          : %s", nftAddress);
        console.log("market admin : %s", marketAdmin);
        console.log("");

        // 1. 部署 V1 到透明代理后面；ProxyAdmin 的 owner 是部署者
        bytes memory initData = abi.encodeCall(
            NFTMarketV1.initialize,
            (tokenAddress, nftAddress, marketAdmin)
        );
        proxy = Upgrades.deployTransparentProxy(
            "NFTMarketV1.sol:NFTMarketV1",
            deployer,
            initData
        );
        v1Implementation = Upgrades.getImplementationAddress(proxy);
        console.log("transparent proxy          : %s", proxy);
        console.log("ProxyAdmin                 : %s", Upgrades.getAdminAddress(proxy));
        console.log("NFTMarketV1 implementation : %s", v1Implementation);

        // 2. 升级到 V2（带升级安全性校验）
        Upgrades.upgradeProxy(proxy, "NFTMarketV2.sol:NFTMarketV2", "");
        v2Implementation = Upgrades.getImplementationAddress(proxy);
        console.log("NFTMarketV2 implementation : %s", v2Implementation);
        console.log("");

        // 3. 升级后通过代理读取状态，确认初始化数据仍在
        market = NFTMarketV2(proxy);
        console.log("market.token    : %s", address(market.token()));
        console.log("market.nft      : %s", address(market.nft()));
        console.log("market.admin    : %s", market.admin());

        // 4. 保存合约地址到本地
        saveContract("NFTMarketV2", proxy);
        saveContract("NFTMarketV1_Impl", v1Implementation);
        saveContract("NFTMarketV2_Impl", v2Implementation);
    }

    /// @dev 先读环境变量，再回退到 deployments/<Name>_<chainId>.json。
    function _loadAddress(
        string memory envName,
        string memory deploymentName
    ) private view returns (address) {
        address addr = vm.envOr(envName, address(0));
        if (addr != address(0)) return addr;

        string memory path = string.concat(
            "deployments/",
            deploymentName,
            "_",
            vm.toString(block.chainid),
            ".json"
        );
        addr = vm.parseJsonAddress(vm.readFile(path), ".address");
        require(addr != address(0), string.concat(deploymentName, " address is zero"));
        return addr;
    }
}
