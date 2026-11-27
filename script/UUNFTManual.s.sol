// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUNFT} from "../src/UUNFT.sol";

/// @notice 手动部署 UUPS 可升级 NFT（UUNFT）——保留此脚本用于和
///         script/UUNFT.s.sol（OpenZeppelin Upgrades 插件版本）做对比：
///         1. 手动 new UUNFT() 部署实现合约（构造函数已 _disableInitializers，不能直接初始化）；
///         2. 手动 new ERC1967Proxy(实现地址, initData) 部署代理并初始化；
///         3. 代理地址保存为 deployments/UUNFT_Manual_<chainId>.json；
///            实现合约地址保存为 deployments/UUNFT_Manual_Impl_<chainId>.json。
///         与插件版本不同，手动部署不会做升级安全性校验（存储布局、initializer 等）。
/// 用法（需要环境变量 PRIVATE_KEY）:
///   PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/UUNFTManual.s.sol:UUNFTManualScript \
///     --rpc-url $RPC_URL --broadcast
contract UUNFTManualScript is BaseScript {
    UUNFT public implementation;
    ERC1967Proxy public proxy;
    UUNFT public nft;

    function run() public broadcaster {
        // 1. 部署实现合约
        implementation = new UUNFT();
        console.log("UUNFT implementation deployed on %s", address(implementation));

        // 2. 编码 initialize 调用，owner 默认是部署者
        address initialOwner = vm.envOr("ADMIN_ADDRESS", deployer);
        bytes memory initData = abi.encodeCall(UUNFT.initialize, (initialOwner));

        // 3. 部署代理并初始化；owner / nextTokenId / version 等状态都会写入代理存储
        proxy = new ERC1967Proxy(address(implementation), initData);
        nft = UUNFT(address(proxy));
        console.log("UUNFT proxy (use this address) deployed on %s", address(proxy));

        console.log("");
        console.log("implementation : %s", address(implementation));
        console.log("proxy          : %s", address(proxy));
        console.log("owner          : %s", nft.owner());
        console.log("nextTokenId    : %s", nft.nextTokenId());
        console.log("version        : %s", nft.version());

        // 4. 保存合约地址到本地（使用 _Manual 后缀，避免覆盖插件版本的部署记录）
        saveContract("UUNFT_Manual", address(proxy));
        saveContract("UUNFT_Manual_Impl", address(implementation));
    }
}
